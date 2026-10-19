import json
import os

import boto3
from botocore.config import Config


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])

BUCKET_NAME = os.environ["ATTACHMENTS_BUCKET"]
URL_EXPIRY_SECONDS = 300  # the link stops working after 5 minutes

# Signature v4 + the bucket's region, so the presigned URL works first time
# (without these, S3 can answer with a redirect that breaks the signature).
s3_client = boto3.client(
    "s3",
    region_name="eu-west-2",
    config=Config(signature_version="s3v4")
)


def build_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }


def safe_filename(name):
    """Keeps the file name safe to put inside a Content-Disposition header."""
    cleaned = "".join(ch for ch in name if ch.isprintable() and ch not in '"\\;')
    return cleaned or "attachment"


def lambda_handler(event, context):
    try:
        path_params = event.get("pathParameters") or {}
        incident_id = path_params.get("incidentId")
        attachment_id = path_params.get("attachmentId")

        if not incident_id or not attachment_id:
            return build_response(400, {"message": "incidentId and attachmentId are required"})

        incident = table.get_item(Key={"incidentId": incident_id}).get("Item")
        if not incident:
            return build_response(404, {"message": "Incident not found"})

        # SECURITY: the S3 location comes from OUR database record, never from the
        # browser. A caller can only ever get a link to a file that is really
        # attached to this incident.
        attachment = next(
            (a for a in incident.get("attachments", []) if a.get("attachmentId") == attachment_id),
            None
        )
        if not attachment:
            return build_response(404, {"message": "Attachment not found on this incident"})

        file_name = safe_filename(attachment.get("fileName", "attachment"))

        download_url = s3_client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": attachment["objectKey"],
                # "inline" = open in the browser tab (images, PDFs, text) instead of forcing a download
                "ResponseContentDisposition": f'inline; filename="{file_name}"'
            },
            ExpiresIn=URL_EXPIRY_SECONDS
        )

        return build_response(200, {
            "downloadUrl": download_url,
            "fileName": attachment.get("fileName"),
            "expiresInSeconds": URL_EXPIRY_SECONDS
        })

    except Exception as error:
        print(f"ERROR: {str(error)}")
        return build_response(500, {"message": "Internal server error"})
