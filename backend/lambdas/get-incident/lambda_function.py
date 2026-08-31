import json
import os

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
            "body": json.dumps(incident)
        }

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Internal server error"})
        }
