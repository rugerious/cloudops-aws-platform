import json
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

events_client = boto3.client("events")
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]  # set by Terraform (was hardcoded to cloudops-dev-events)

geo_client = boto3.client("geo-places", region_name="eu-west-2")


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


def geocode_location(location_text):
    """Returns (lat, lng) tuple, or (None, None) if geocoding fails or finds nothing."""
    if not location_text:
        return None, None
    try:
        response = geo_client.geocode(
            QueryText=location_text,
            MaxResults=1,
            IntendedUse="Storage"  # required since we persist the result on the incident record
        )
        results = response.get("ResultItems", [])
        if not results:
            return None, None
        lng, lat = results[0]["Position"]  # API returns [lng, lat] order — easy to get backwards
        return lat, lng
    except Exception as error:
        print(f"WARNING: Geocoding failed for '{location_text}': {str(error)}")
        return None, None


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

        lat, lng = geocode_location(incident["location"])
        if lat is not None:
            incident["lat"] = lat
            incident["lng"] = lng

        # DynamoDB (via boto3) rejects Python floats, so store coordinates as Decimal.
        # The original `incident` keeps floats, because json.dumps can't serialise Decimal.
        dynamodb_item = dict(incident)
        if "lat" in dynamodb_item:
            dynamodb_item["lat"] = Decimal(str(dynamodb_item["lat"]))
            dynamodb_item["lng"] = Decimal(str(dynamodb_item["lng"]))
        table.put_item(Item=dynamodb_item)

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