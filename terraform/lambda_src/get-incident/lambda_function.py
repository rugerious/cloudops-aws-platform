import json
import os
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def decimal_to_json(value):
    """Tells json.dumps how to handle Decimal values returned by DynamoDB."""
    if isinstance(value, Decimal):
        # Whole numbers become int (e.g. 3), everything else becomes float (e.g. 51.4935)
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def lambda_handler(event, context):
    try:
        incident_id = event.get("pathParameters", {}).get("incidentId")

        if not incident_id:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "incidentId is required"})
            }

        response = table.get_item(Key={"incidentId": incident_id})
        incident = response.get("Item")

        if not incident:
            return {
                "statusCode": 404,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "Incident not found"})
            }

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(incident, default=decimal_to_json)
        }

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Internal server error"})
        }