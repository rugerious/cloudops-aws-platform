import base64
import json
import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

INDEX_NAME = "status-createdAt-index"
ACTIVE_STATUSES = ["OPEN", "IN_PROGRESS"]
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 50


def decimal_to_json(value):
    """Tells json.dumps how to handle Decimal values returned by DynamoDB."""
    if isinstance(value, Decimal):
        # Whole numbers become int (e.g. 3), everything else becomes float (e.g. 51.4935)
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def build_response(status_code, body):
    """Builds an API Gateway response, handling Decimal values in the body."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=decimal_to_json)
    }


def encode_token(last_evaluated_key):
    """Turns DynamoDB's LastEvaluatedKey into an opaque, URL-safe text token for the client."""
    return base64.urlsafe_b64encode(json.dumps(last_evaluated_key).encode("utf-8")).decode("utf-8")


def decode_token(token):
    """Turns a token from the client back into DynamoDB's ExclusiveStartKey."""
    return json.loads(base64.urlsafe_b64decode(token.encode("utf-8")).decode("utf-8"))


def query_all_with_status(status):
    """Returns ALL incidents with this status, newest first, following DynamoDB's pages."""
    items = []
    query_args = {
        "IndexName": INDEX_NAME,
        "KeyConditionExpression": Key("status").eq(status),
        "ScanIndexForward": False  # False = newest createdAt first
    }
    while True:
        response = table.query(**query_args)
        items.extend(response.get("Items", []))
        if "LastEvaluatedKey" not in response:
            return items
        query_args["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def count_with_status(status):
    """Counts incidents with this status without returning them (Select=COUNT)."""
    total = 0
    query_args = {
        "IndexName": INDEX_NAME,
        "KeyConditionExpression": Key("status").eq(status),
        "Select": "COUNT"
    }
    while True:
        response = table.query(**query_args)
        total += response.get("Count", 0)
        if "LastEvaluatedKey" not in response:
            return total
        query_args["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def list_active():
    """Active tab: every OPEN and IN_PROGRESS incident, merged and sorted newest first."""
    open_incidents = query_all_with_status("OPEN")
    in_progress_incidents = query_all_with_status("IN_PROGRESS")

    incidents = open_incidents + in_progress_incidents
    incidents.sort(key=lambda incident: incident["createdAt"], reverse=True)

    # Active counts come for free from the lists we already loaded.
    # RESOLVED and CLOSED need a count query each.
    resolved_count = count_with_status("RESOLVED")
    closed_count = count_with_status("CLOSED")

    return build_response(200, {
        "view": "active",
        "count": len(incidents),
        "incidents": incidents,
        "counts": {
            "OPEN": len(open_incidents),
            "IN_PROGRESS": len(in_progress_incidents),
            "RESOLVED": resolved_count,
            "CLOSED": closed_count,
            "total": len(incidents) + resolved_count + closed_count
        }
    })


def list_resolved():
    """To verify tab: every RESOLVED incident waiting for manager sign-off.
    A small queue, so it's loaded in one go, oldest resolution first (longest waiting at the top)."""
    incidents = query_all_with_status("RESOLVED")
    incidents.sort(key=lambda incident: incident.get("resolvedAt") or incident["createdAt"])
    return build_response(200, {
        "view": "resolved",
        "count": len(incidents),
        "incidents": incidents
    })


def list_closed(params):
    """Closed tab: one page of CLOSED incidents, newest first, with a token for the next page."""
    try:
        limit = int(params.get("limit", DEFAULT_PAGE_SIZE))
    except ValueError:
        return build_response(400, {"message": "limit must be a whole number"})

    if limit < 1 or limit > MAX_PAGE_SIZE:
        return build_response(400, {"message": f"limit must be between 1 and {MAX_PAGE_SIZE}"})

    query_args = {
        "IndexName": INDEX_NAME,
        "KeyConditionExpression": Key("status").eq("CLOSED"),
        "ScanIndexForward": False,
        "Limit": limit
    }

    next_token = params.get("nextToken")
    if next_token:
        try:
            query_args["ExclusiveStartKey"] = decode_token(next_token)
        except Exception:
            return build_response(400, {"message": "Invalid nextToken"})

    response = table.query(**query_args)
    incidents = response.get("Items", [])

    # DynamoDB only includes LastEvaluatedKey when there may be more items.
    last_key = response.get("LastEvaluatedKey")

    return build_response(200, {
        "view": "closed",
        "count": len(incidents),
        "incidents": incidents,
        "nextToken": encode_token(last_key) if last_key else None
    })


def lambda_handler(event, context):
    try:
        params = event.get("queryStringParameters") or {}
        view = params.get("view", "active")

        if view == "active":
            return list_active()

        if view == "resolved":
            return list_resolved()

        if view == "closed":
            return list_closed(params)

        return build_response(400, {
            "message": "Invalid view",
            "allowedValues": ["active", "resolved", "closed"]
        })

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return build_response(500, {"message": "Internal server error"})
