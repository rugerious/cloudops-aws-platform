import json
import os
import re
import uuid
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

BUCKET_NAME = os.environ["ATTACHMENTS_BUCKET"]
ALLOWED_CONTENT_TYPES = ["image/jpeg", "image/png", "application/pdf", "text/plain"]
URL_EXPIRY_SECONDS = 300
MAX_FILE_NAME_LENGTH = 100
# Only operational staff may attach files. Logged in without a group = view only.
OPERATIONAL_GROUPS = ["FieldEngineers", "Managers", "Admins"]


def respond(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }


def get_claims(event):
    return (event.get("requestContext") or {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def get_user_groups(claims):
    groups_raw = claims.get("cognito:groups", "")
    if not groups_raw:
        return []
    cleaned = groups_raw.strip("[]")
    return [group.strip() for group in cleaned.split(",") if group.strip()]


def safe_key_name(file_name):
    """File name used inside the S3 key: only letters, digits, dot, dash and underscore.
    Characters like '#', '?' or spaces have special meanings in web addresses."""
    base = os.path.basename(file_name.replace("\\", "/"))
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", base).strip("._") or "file"
    return cleaned[-MAX_FILE_NAME_LENGTH:]


def lambda_handler(event, context):
    try:
        claims = get_claims(event)
        if not any(group in OPERATIONAL_GROUPS for group in get_user_groups(claims)):
            return respond(403, {"message": "Forbidden: only engineers, managers or admins can attach files"})

        incident_id = (event.get("pathParameters") or {}).get("incidentId")
        if not incident_id:
            return respond(400, {"message": "incidentId is required"})

        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return respond(400, {"message": "Request body must be valid JSON"})
        if not isinstance(body, dict):
            return respond(400, {"message": "Request body must be a JSON object"})

        file_name = body.get("fileName")
        content_type = body.get("contentType")

        if not isinstance(file_name, str) or not file_name.strip() or not content_type:
            return respond(400, {"message": "fileName and contentType are required"})

        if content_type not in ALLOWED_CONTENT_TYPES:
            return respond(400, {"message": "Unsupported content type", "allowedTypes": ALLOWED_CONTENT_TYPES})

        uploaded_by = claims.get("email") or claims.get("cognito:username") or claims.get("sub") or "unknown"

        display_name = file_name.strip()[:200]
        attachment_id = str(uuid.uuid4())
        object_key = f"incidents/{incident_id}/{attachment_id}-{safe_key_name(display_name)}"
        uploaded_at = datetime.now(timezone.utc).isoformat()

        attachment_record = {
            "attachmentId": attachment_id,
            "fileName": display_name,
            "objectKey": object_key,
            "uploadedAt": uploaded_at,
            "uploadedBy": uploaded_by
        }

        # Rule: once an incident is CLOSED, nothing changes, including attachments.
        # (RESOLVED is still allowed, so an engineer can add a forgotten photo before sign-off.)
        try:
            table.update_item(
                Key={"incidentId": incident_id},
                UpdateExpression="SET attachments = list_append(if_not_exists(attachments, :emptyList), :newAttachment)",
                ConditionExpression="attribute_exists(incidentId) AND #st <> :closed",
                ExpressionAttributeNames={"#st": "status"},
                ExpressionAttributeValues={
                    ":emptyList": [],
                    ":newAttachment": [attachment_record],
                    ":closed": "CLOSED"
                }
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            existing = table.get_item(Key={"incidentId": incident_id}).get("Item")
            if not existing:
                return respond(404, {"message": "Incident not found"})
            return respond(409, {"message": "Incident is CLOSED: no more files can be attached"})

        presigned_url = s3.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": object_key,
                "ContentType": content_type
            },
            ExpiresIn=URL_EXPIRY_SECONDS
        )

        return respond(200, {
            "uploadUrl": presigned_url,
            "objectKey": object_key,
            "expiresIn": URL_EXPIRY_SECONDS,
            "attachment": attachment_record
        })

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return respond(500, {"message": "Internal server error"})