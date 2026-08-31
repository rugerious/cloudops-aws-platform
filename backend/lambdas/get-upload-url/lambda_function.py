import json
import os
import uuid
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

BUCKET_NAME = os.environ["ATTACHMENTS_BUCKET"]
ALLOWED_CONTENT_TYPES = ["image/jpeg", "image/png", "application/pdf", "text/plain"]
URL_EXPIRY_SECONDS = 300


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
        file_name = body.get("fileName")
        content_type = body.get("contentType")

        if not file_name or not content_type:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "fileName and contentType are required"})
            }

        if content_type not in ALLOWED_CONTENT_TYPES:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "message": "Unsupported content type",
                    "allowedTypes": ALLOWED_CONTENT_TYPES
                })
            }

        attachment_id = str(uuid.uuid4())
        object_key = f"incidents/{incident_id}/{attachment_id}-{file_name}"
        uploaded_at = datetime.now(timezone.utc).isoformat()

        presigned_url = s3.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": object_key,
                "ContentType": content_type
            },
            ExpiresIn=URL_EXPIRY_SECONDS
        )

        attachment_record = {
            "attachmentId": attachment_id,
            "fileName": file_name,
            "objectKey": object_key,
            "uploadedAt": uploaded_at
        }

        table.update_item(
            Key={"incidentId": incident_id},
            UpdateExpression="SET attachments = list_append(if_not_exists(attachments, :emptyList), :newAttachment)",
            ConditionExpression="attribute_exists(incidentId)",
            ExpressionAttributeValues={
                ":emptyList": [],
                ":newAttachment": [attachment_record]
            }
        )

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "uploadUrl": presigned_url,
                "objectKey": object_key,
                "expiresIn": URL_EXPIRY_SECONDS,
                "attachment": attachment_record
            })
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
