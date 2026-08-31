import json
import os

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

UPDATABLE_FIELDS = ["title", "description", "severity", "status", "location", "device"]
VALID_SEVERITIES = ["P1", "P2", "P3", "P4"]
VALID_STATUSES = ["OPEN", "IN_PROGRESS", "CLOSED"]


def lambda_handler(event, context):
    try:
        incident_id = event.get("pathParameters", {}).get("incidentId")

        if not incident_id:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "incidentId is required"})
            }

        body = json.loads(event.get("body", "{}"))

        fields_to_update = {
            key: value for key, value in body.items()
            if key in UPDATABLE_FIELDS
        }

        if not fields_to_update:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "No valid fields to update",
                    "allowedFields": UPDATABLE_FIELDS
                })
            }

        if "severity" in fields_to_update and fields_to_update["severity"] not in VALID_SEVERITIES:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Invalid severity",
                    "allowedValues": VALID_SEVERITIES
                })
            }

        if "status" in fields_to_update and fields_to_update["status"] not in VALID_STATUSES:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Invalid status",
                    "allowedValues": VALID_STATUSES
                })
            }

        update_expression_parts = []
        expression_attribute_names = {}
        expression_attribute_values = {}

        for field_name, field_value in fields_to_update.items():
            placeholder_name = f"#{field_name}"
            placeholder_value = f":{field_name}"

            update_expression_parts.append(f"{placeholder_name} = {placeholder_value}")
            expression_attribute_names[placeholder_name] = field_name
            expression_attribute_values[placeholder_value] = field_value

        update_expression = "SET " + ", ".join(update_expression_parts)

        response = table.update_item(
            Key={"incidentId": incident_id},
            UpdateExpression=update_expression,
            ExpressionAttributeNames=expression_attribute_names,
            ExpressionAttributeValues=expression_attribute_values,
            ConditionExpression="attribute_exists(incidentId)",
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
