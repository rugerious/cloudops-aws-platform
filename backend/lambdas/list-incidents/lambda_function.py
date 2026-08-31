import json
import os

import boto3


dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    try:
        response = table.scan()
        incidents = response.get("Items", [])

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "count": len(incidents),
                "incidents": incidents
            })
        }

    except Exception as error:
        print(f"ERROR: {str(error)}")

        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Internal server error"})
        }
