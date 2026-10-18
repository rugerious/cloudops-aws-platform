import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

geo_client = boto3.client("geo-places", region_name="eu-west-2")

# Fields anyone logged in may edit (while the incident is still active).
EDITABLE_FIELDS = ["title", "description", "location", "device"]
# Only operational staff may change incidents. Logged in without a group = view only.
OPERATIONAL_GROUPS = ["FieldEngineers", "Managers", "Admins"]
# Severity changes are a decision, so only Managers and Admins may make them.
SEVERITY_GROUPS = ["Managers", "Admins"]
VALID_SEVERITIES = ["P1", "P2", "P3", "P4"]

# The ONLY status change this route allows is starting work: OPEN -> IN_PROGRESS.
# Every other status change has its own route with its own role check:
#   /acknowledge, /resolve, /close (manager sign-off), /reopen
ACTIVE_STATUSES = ["OPEN", "IN_PROGRESS"]


def decimal_default(obj):
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    raise TypeError(f"Not serializable: {type(obj)}")


def respond(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=decimal_default)
    }


def get_claims(event):
    return (event.get("requestContext") or {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def get_user_groups(claims):
    groups_raw = claims.get("cognito:groups", "")
    if not groups_raw:
        return []
    cleaned = groups_raw.strip("[]")
    return [group.strip() for group in cleaned.split(",") if group.strip()]


def geocode_location(location_text):
    """Returns (lat, lng) as Decimals, or (None, None) if geocoding fails or finds nothing."""
    if not location_text:
        return None, None
    try:
        response = geo_client.geocode(
            QueryText=location_text,
            MaxResults=1,
            IntendedUse="Storage"
        )
        results = response.get("ResultItems", [])
        if not results:
            return None, None
        lng, lat = results[0]["Position"]  # API returns [lng, lat]
        return Decimal(str(lat)), Decimal(str(lng))
    except Exception as error:
        print(f"WARNING: Geocoding failed for '{location_text}': {str(error)}")
        return None, None


def lambda_handler(event, context):
    try:
        claims = get_claims(event)
        user_groups = get_user_groups(claims)
        updated_by = claims.get("email") or claims.get("cognito:username") or claims.get("sub") or "unknown"

        if not any(group in OPERATIONAL_GROUPS for group in user_groups):
            return respond(403, {"message": "Forbidden: only engineers, managers or admins can change incidents"})

        incident_id = (event.get("pathParameters") or {}).get("incidentId")
        if not incident_id:
            return respond(400, {"message": "incidentId is required"})

        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return respond(400, {"message": "Request body must be valid JSON"})
        if not isinstance(body, dict):
            return respond(400, {"message": "Request body must be a JSON object"})

        # ── Status: only "start work" is allowed here ──
        wants_start = False
        if "status" in body:
            if body["status"] != "IN_PROGRESS":
                return respond(400, {
                    "message": "This route can only start work (status IN_PROGRESS). "
                               "Use /acknowledge, /resolve, /close or /reopen for other status changes."
                })
            wants_start = True

        # ── Severity: Managers and Admins only ──
        if "severity" in body:
            if not any(group in SEVERITY_GROUPS for group in user_groups):
                return respond(403, {"message": "Forbidden: only Managers or Admins can change severity"})
            if body["severity"] not in VALID_SEVERITIES:
                return respond(400, {"message": "Invalid severity", "allowedValues": VALID_SEVERITIES})

        fields_to_update = {
            key: value for key, value in body.items()
            if key in EDITABLE_FIELDS or key == "severity"
        }
        if wants_start:
            fields_to_update["status"] = "IN_PROGRESS"

        unknown_fields = [key for key in body if key not in EDITABLE_FIELDS + ["severity", "status"]]
        if unknown_fields:
            return respond(400, {
                "message": "These fields cannot be changed here",
                "fields": unknown_fields,
                "allowedFields": EDITABLE_FIELDS + ["severity", "status"]
            })

        if not fields_to_update:
            return respond(400, {
                "message": "No valid fields to update",
                "allowedFields": EDITABLE_FIELDS + ["severity", "status"]
            })

        for key in EDITABLE_FIELDS:
            if key in fields_to_update and (not isinstance(fields_to_update[key], str) or not fields_to_update[key].strip()):
                return respond(400, {"message": f"{key} must be non-empty text"})

        remove_fields = []
        if "location" in fields_to_update:
            lat, lng = geocode_location(fields_to_update["location"])
            if lat is not None:
                fields_to_update["lat"] = lat
                fields_to_update["lng"] = lng
            else:
                # New address couldn't be geocoded: drop the old coordinates
                # so the map doesn't show a pin at the previous location.
                remove_fields = ["lat", "lng"]

        fields_to_update["updatedAt"] = datetime.now(timezone.utc).isoformat()
        # Who made the change comes from the verified login token, never from the body.
        fields_to_update["updatedBy"] = updated_by

        names = {"#st": "status"}
        # DynamoDB rejects any placeholder that isn't used in an expression,
        # so only add ":inprog" when the condition actually uses it.
        values = {":open": "OPEN"}
        if not wants_start:
            values[":inprog"] = "IN_PROGRESS"
        set_parts = []
        for index, (field_name, field_value) in enumerate(fields_to_update.items()):
            names[f"#f{index}"] = field_name
            values[f":v{index}"] = field_value
            set_parts.append(f"#f{index} = :v{index}")

        update_expression = "SET " + ", ".join(set_parts)

        if remove_fields:
            remove_parts = []
            for index, field_name in enumerate(remove_fields):
                names[f"#r{index}"] = field_name
                remove_parts.append(f"#r{index}")
            update_expression += " REMOVE " + ", ".join(remove_parts)

        # Only active incidents can be edited. Starting work is only possible from OPEN.
        if wants_start:
            condition = "attribute_exists(incidentId) AND #st = :open"
        else:
            condition = "attribute_exists(incidentId) AND #st IN (:open, :inprog)"

        try:
            response = table.update_item(
                Key={"incidentId": incident_id},
                UpdateExpression=update_expression,
                ConditionExpression=condition,
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW"
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            existing = table.get_item(Key={"incidentId": incident_id}).get("Item")
            if not existing:
                return respond(404, {"message": "Incident not found"})
            current = existing.get("status")
            if wants_start and current == "IN_PROGRESS":
                return respond(409, {"message": "Work has already started on this incident"})
            return respond(409, {"message": f"Incident is {current} and can no longer be edited here"})

        return respond(200, response["Attributes"])

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return respond(500, {"message": "Internal server error"})