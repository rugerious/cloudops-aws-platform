import json
import os
import uuid
from datetime import datetime, timezone

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

events_client = boto3.client("events")
EVENT_BUS_NAME = "cloudops-dev-events"


def publish_incident_created_event(incident):
    try:
        events_client.put_events(
            Entries=[
                {
                    "Source": "cloudops.incidents",
                    "DetailType": "IncidentCreated",
                    "Detail": json.dumps(incident),
                    "EventBusName": EVENT_BUS_NAME
                }
            ]
        )
    except Exception as error:
        print(f"WARNING: Failed to publish event: {str(error)}")


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))

        required_fields = [
            "title",
            "description",
            "severity",
            "location",
            "device"
        ]

        missing_fields = [
            field for field in required_fields
            if not body.get(field)
        ]

        if missing_fields:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Missing required fields",
                    "fields": missing_fields
                })
            }

        valid_severities = ["P1", "P2", "P3", "P4"]

        if body["severity"] not in valid_severities:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Invalid severity",
                    "allowedValues": valid_severities
                })
            }

        incident_id = str(uuid.uuid4())
        created_at = datetime.now(timezone.utc).isoformat()

        incident = {
            "incidentId": incident_id,
            "title": body["title"],
            "description": body["description"],
            "severity": body["severity"],
            "location": body["location"],
            "device": body["device"],
            "status": "OPEN",
            "createdAt": created_at
        }

        table.put_item(Item=incident)

        publish_incident_created_event(incident)

        return {
            "statusCode": 201,
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
