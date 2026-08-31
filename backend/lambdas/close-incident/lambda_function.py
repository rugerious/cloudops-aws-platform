import json
import os
from datetime import datetime, timezone

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

ALLOWED_GROUPS = ["Managers", "Admins"]


def get_user_groups(event):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    groups_raw = claims.get("cognito:groups", "")

    if not groups_raw:
        return []

    cleaned = groups_raw.strip("[]")
    return [group.strip() for group in cleaned.split(",") if group.strip()]


def lambda_handler(event, context):
    try:
        user_groups = get_user_groups(event)

        if not any(group in ALLOWED_GROUPS for group in user_groups):
            return {
                "statusCode": 403,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Forbidden: only Managers or Admins can close incidents"
                })
            }

        incident_id = event.get("pathParameters", {}).get("incidentId")

        if not incident_id:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "incidentId is required"})
            }

        closed_at = datetime.now(timezone.utc).isoformat()

        response = table.update_item(
            Key={"incidentId": incident_id},
            UpdateExpression="SET #status = :closedStatus, closedAt = :closedAt",
            ConditionExpression="attribute_exists(incidentId) AND #status <> :closedStatus",
            ExpressionAttributeNames={
                "#status": "status"
            },
            ExpressionAttributeValues={
                ":closedStatus": "CLOSED",
                ":closedAt": closed_at
            },
            ReturnValues="ALL_NEW"
        )

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(response["Attributes"])
        }

    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return {
            "statusCode": 409,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Incident does not exist or is already closed"})
        }

    except Exception as error:
        print(f"ERROR: {str(error)}")

        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Internal server error"})
        }
