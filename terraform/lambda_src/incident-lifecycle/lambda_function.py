"""
Incident lifecycle actions, one function for two routes:

  POST /incidents/{incidentId}/resolve   engineer says "it's fixed"   OPEN | IN_PROGRESS -> RESOLVED
  POST /incidents/{incidentId}/reopen    manager says "not fixed"     RESOLVED -> IN_PROGRESS

Closing (manager sign-off, RESOLVED -> CLOSED) stays in the CloseIncident function.
Every action is also appended to the incident's "history" list (who, what, when, note),
so the dashboard timeline can show the full story, including reopen cycles.
"""
import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

OPERATIONAL_GROUPS = ["FieldEngineers", "Managers", "Admins"]
MANAGER_GROUPS = ["Managers", "Admins"]
MAX_TEXT_LENGTH = 1000


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


def get_action(event):
    """Works out which route was called: 'resolve' or 'reopen'."""
    route_key = event.get("routeKey") or ""
    path = event.get("rawPath") or route_key
    for action in ("resolve", "reopen"):
        if path.rstrip("/").endswith("/" + action):
            return action
    return None


def read_text(body, field):
    """Returns (text, error_message). Text is required, trimmed, and length-limited."""
    value = body.get(field)
    if not isinstance(value, str) or not value.strip():
        return None, f"{field} is required"
    value = value.strip()
    if len(value) > MAX_TEXT_LENGTH:
        return None, f"{field} must be {MAX_TEXT_LENGTH} characters or fewer"
    return value, None


def explain_refusal(incident_id, action):
    existing = table.get_item(Key={"incidentId": incident_id}).get("Item")
    if not existing:
        return respond(404, {"message": "Incident not found"})
    current = existing.get("status")
    if action == "resolve":
        return respond(409, {"message": f"Only OPEN or IN_PROGRESS incidents can be resolved (this one is {current})"})
    return respond(409, {"message": f"Only RESOLVED incidents can be reopened (this one is {current})"})


def lambda_handler(event, context):
    try:
        action = get_action(event)
        if not action:
            return respond(404, {"message": "Unknown action"})

        incident_id = (event.get("pathParameters") or {}).get("incidentId")
        if not incident_id:
            return respond(400, {"message": "incidentId is required"})

        claims = get_claims(event)
        groups = get_user_groups(claims)
        # Who did it comes from the verified login token, never from the request body.
        actor = claims.get("email") or claims.get("cognito:username") or claims.get("sub") or "unknown"

        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return respond(400, {"message": "Request body must be valid JSON"})
        if not isinstance(body, dict):
            return respond(400, {"message": "Request body must be a JSON object"})

        now = datetime.now(timezone.utc).isoformat()

        if action == "resolve":
            if not any(group in OPERATIONAL_GROUPS for group in groups):
                return respond(403, {"message": "Forbidden: only engineers, managers or admins can resolve incidents"})

            note, error = read_text(body, "resolutionNote")
            if error:
                return respond(400, {"message": error})

            history_entry = {"action": "RESOLVED", "by": actor, "at": now, "note": note}
            update_expression = (
                "SET #st = :resolved, resolvedAt = :now, resolvedBy = :actor, resolutionNote = :note, "
                "updatedAt = :now, updatedBy = :actor, "
                "history = list_append(if_not_exists(history, :empty), :entry)"
            )
            condition = "attribute_exists(incidentId) AND #st IN (:open, :inprog)"
            values = {
                ":resolved": "RESOLVED",
                ":open": "OPEN",
                ":inprog": "IN_PROGRESS",
                ":now": now,
                ":actor": actor,
                ":note": note,
                ":empty": [],
                ":entry": [history_entry]
            }

        else:  # reopen
            if not any(group in MANAGER_GROUPS for group in groups):
                return respond(403, {"message": "Forbidden: only Managers or Admins can reopen incidents"})

            reason, error = read_text(body, "reason")
            if error:
                return respond(400, {"message": error})

            history_entry = {"action": "REOPENED", "by": actor, "at": now, "note": reason}
            # Back to work. The previous resolution stays in "history", but is removed
            # from the incident itself, because it turned out not to be the fix.
            update_expression = (
                "SET #st = :inprog, reopenedAt = :now, reopenedBy = :actor, reopenReason = :reason, "
                "reopenCount = if_not_exists(reopenCount, :zero) + :one, "
                "updatedAt = :now, updatedBy = :actor, "
                "history = list_append(if_not_exists(history, :empty), :entry) "
                "REMOVE resolvedAt, resolvedBy, resolutionNote"
            )
            condition = "attribute_exists(incidentId) AND #st = :resolved"
            values = {
                ":inprog": "IN_PROGRESS",
                ":resolved": "RESOLVED",
                ":now": now,
                ":actor": actor,
                ":reason": reason,
                ":zero": 0,
                ":one": 1,
                ":empty": [],
                ":entry": [history_entry]
            }

        try:
            response = table.update_item(
                Key={"incidentId": incident_id},
                UpdateExpression=update_expression,
                ConditionExpression=condition,
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW"
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            return explain_refusal(incident_id, action)

        return respond(200, response["Attributes"])

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return respond(500, {"message": "Internal server error"})