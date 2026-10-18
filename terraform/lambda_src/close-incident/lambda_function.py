"""
Close = manager sign-off.

  POST /incidents/{incidentId}/close    RESOLVED -> CLOSED    Managers and Admins only

An engineer resolves ("I believe it's fixed"), a manager closes ("confirmed, finished").
After this, the incident is a locked record: nothing else can change it.
"""
import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

ALLOWED_GROUPS = ["Managers", "Admins"]
MAX_NOTE_LENGTH = 1000


def decimal_to_json(value):
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
        if not any(group in ALLOWED_GROUPS for group in get_user_groups(claims)):
            return respond(403, {"message": "Forbidden: only Managers or Admins can close incidents"})

        incident_id = (event.get("pathParameters") or {}).get("incidentId")
        if not incident_id:
            return respond(400, {"message": "incidentId is required"})

        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return respond(400, {"message": "Request body must be valid JSON"})
        if not isinstance(body, dict):
            return respond(400, {"message": "Request body must be a JSON object"})

        # Optional sign-off comment from the manager.
        close_note = body.get("closeNote")
        if close_note is not None:
            if not isinstance(close_note, str):
                return respond(400, {"message": "closeNote must be text"})
            close_note = close_note.strip()
            if len(close_note) > MAX_NOTE_LENGTH:
                return respond(400, {"message": f"closeNote must be {MAX_NOTE_LENGTH} characters or fewer"})

        now = datetime.now(timezone.utc).isoformat()
        # Who closed it comes from the verified login token, never from the request body.
        closed_by = claims.get("email") or claims.get("cognito:username") or claims.get("sub") or "unknown"

        history_entry = {"action": "CLOSED", "by": closed_by, "at": now}
        update_expression = (
            "SET #st = :closed, closedAt = :now, closedBy = :by, updatedAt = :now, updatedBy = :by, "
            "history = list_append(if_not_exists(history, :empty), :entry)"
        )
        values = {
            ":closed": "CLOSED",
            ":resolved": "RESOLVED",
            ":now": now,
            ":by": closed_by,
            ":empty": [],
            ":entry": [history_entry]
        }
        if close_note:
            history_entry["note"] = close_note
            update_expression += ", closeNote = :note"
            values[":note"] = close_note

        try:
            response = table.update_item(
                Key={"incidentId": incident_id},
                UpdateExpression=update_expression,
                # Sign-off is only possible once an engineer has resolved it.
                ConditionExpression="attribute_exists(incidentId) AND #st = :resolved",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW"
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            existing = table.get_item(Key={"incidentId": incident_id}).get("Item")
            if not existing:
                return respond(404, {"message": "Incident not found"})
            current = existing.get("status")
            if current == "CLOSED":
                return respond(409, {"message": "Incident is already closed"})
            return respond(409, {"message": f"Only RESOLVED incidents can be closed (this one is {current}). Resolve it first."})

        return respond(200, response["Attributes"])

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return respond(500, {"message": "Internal server error"})
