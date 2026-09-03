import json

import boto3

sfn_client = boto3.client("stepfunctions")
STATE_MACHINE_ARN = "arn:aws:states:eu-west-2:845261682900:stateMachine:cloudops-dev-p1-escalation-workflow"


def lambda_handler(event, context):
    for record in event.get("Records", []):
        try:
            message_body = json.loads(record["body"])
            incident_detail = message_body.get("detail", {})

            print(f"P1 ALERT: Incident '{incident_detail.get('title')}' "
                  f"at {incident_detail.get('location')} "
                  f"(ID: {incident_detail.get('incidentId')}) - "
                  f"starting escalation workflow")

            sfn_client.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                input=json.dumps({
                    "incidentId": incident_detail.get("incidentId"),
                    "title": incident_detail.get("title"),
                    "location": incident_detail.get("location")
                })
            )

        except Exception as error:
            print(f"ERROR processing record: {str(error)}")
            raise

    return {"statusCode": 200}
