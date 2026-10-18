import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

# Only operational staff may act on incidents. Logged in without a group = view only.
OPERATIONAL_GROUPS = ["FieldEngineers", "Managers", "Admins"]


def decimal_to_json(value):
    """Tells json.dumps how to handle Decimal values returned by DynamoDB."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def respond(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=decimal_to_json)
    }


def get_claims(event):
    return (event.get("requestContext") or {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def get_user_groups(claims):
    groups_raw = claims.get("cognito:groups", "")
    if not groups_raw:
        return []
    cleaned = groups_raw.strip("[]")
    return [group.strip() for group in cleaned.split(",") if group.strip()]


def lambda_handler(event, context):
    try:
        claims = get_claims(event)
        if not any(group in OPERATIONAL_GROUPS for group in get_user_groups(claims)):
            return respond(403, {"message": "Forbidden: only engineers, managers or admins can acknowledge incidents"})

        incident_id = (event.get("pathParameters") or {}).get("incidentId")
        if not incident_id:
            return respond(400, {"message": "incidentId is required"})

        # Who acknowledged comes from the verified login token, never from the request.
        acknowledged_by = claims.get("email") or claims.get("cognito:username") or claims.get("sub") or "unknown"
        acknowledged_at = datetime.now(timezone.utc).isoformat()

        try:
            response = table.update_item(
                Key={"incidentId": incident_id},
                UpdateExpression="SET acknowledged = :true, acknowledgedAt = :ackAt, acknowledgedBy = :ackBy",
                # Only active incidents can be acknowledged, and only once.
                ConditionExpression=(
                    "attribute_exists(incidentId) "
                    "AND #st IN (:open, :inprog) "
                    "AND (attribute_not_exists(acknowledged) OR acknowledged = :false)"
                ),
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={
                    ":true": True,
                    ":false": False,
                    ":ackAt": acknowledged_at,
                    ":ackBy": acknowledged_by,
                    ":open": "OPEN",
                    ":inprog": "IN_PROGRESS"
                },
                ReturnValues="ALL_NEW"
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            existing = table.get_item(Key={"incidentId": incident_id}).get("Item")
            if not existing:
                return respond(404, {"message": "Incident not found"})
            if existing.get("acknowledged"):
                return respond(409, {"message": "Incident is already acknowledged"})
            return respond(409, {"message": f"Incident is {existing.get('status')} and can no longer be acknowledged"})

        return respond(200, response["Attributes"])

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return respond(500, {"message": "Internal server error"})