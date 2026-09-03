import json
import os
from datetime import datetime, timezone

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    try:
        incident_id = event.get("pathParameters", {}).get("incidentId")

        if not incident_id:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "incidentId is required"})
            }

        acknowledged_at = datetime.now(timezone.utc).isoformat()

        response = table.update_item(
            Key={"incidentId": incident_id},
            UpdateExpression="SET acknowledged = :true, acknowledgedAt = :ackAt",
            ConditionExpression="attribute_exists(incidentId)",
            ExpressionAttributeValues={
                ":true": True,
                ":ackAt": acknowledged_at
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
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Incident not found"})
        }

    except Exception as error:
        print(f"ERROR: {str(error)}")

        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Internal server error"})
        }
