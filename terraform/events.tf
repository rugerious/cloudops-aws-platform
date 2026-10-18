# P1 escalation pipeline (decision 6):
#   CreateIncident -> EventBridge bus -> rule (P1 only) -> Step Functions
#   -> wait 5 min -> read the incident -> acknowledged? stop : email via SNS
# Failed deliveries from EventBridge go to an SQS dead-letter queue.
# Copied from the console pipeline (14 Oct inventory) with these changes:
#   - Step Functions logs errors to CloudWatch (was OFF)
#   - Named IAM policies instead of console-generated ones (*-<uuid>)
#   - DLQ keeps messages 14 days (was 4) so a failure isn't lost over a long weekend

# ---------------------------------------------------------------------------
# SNS: the escalation email
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "p1_escalation" {
  name = "${local.name_prefix}-p1-escalation"
}

# AWS emails a confirmation link to this address. Until it is clicked
# the subscription stays "PendingConfirmation" and no escalation email arrives.
resource "aws_sns_topic_subscription" "p1_escalation_email" {
  topic_arn = aws_sns_topic.p1_escalation.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Step Functions: the escalation workflow
# ---------------------------------------------------------------------------
locals {
  escalation_definition = {
    Comment       = "P1 incident escalation workflow"
    QueryLanguage = "JSONPath"
    StartAt       = "WaitForAcknowledgment"
    States = {
      WaitForAcknowledgment = {
        Type    = "Wait"
        Seconds = var.escalation_wait_seconds
        Next    = "GetIncidentStatus"
      }
      GetIncidentStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:getItem" # direct SDK integration, no Lambda
        Parameters = {
          TableName = aws_dynamodb_table.incidents.name
          Key       = { incidentId = { "S.$" = "$.incidentId" } }
        }
        ResultPath = "$.incidentRecord"
        Next       = "IsAcknowledged"
      }
      IsAcknowledged = {
        Type = "Choice"
        # Bug 7: unacknowledged items have no "acknowledged" field at all,
        # so check IsPresent first; missing = escalate.
        Choices = [{
          And = [
            { Variable = "$.incidentRecord.Item.acknowledged.BOOL", IsPresent = true },
            { Variable = "$.incidentRecord.Item.acknowledged.BOOL", BooleanEquals = true },
          ]
          Next = "NoEscalationNeeded"
        }]
        Default = "EscalateViaSNS"
      }
      NoEscalationNeeded = { Type = "Succeed" }
      EscalateViaSNS = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.p1_escalation.arn
          "Message.$" = "States.Format('ESCALATION: Incident {} ({}) at {} was not acknowledged within 5 minutes and requires immediate attention.', $.incidentId, $.title, $.location)"
          Subject     = "P1 Incident Escalation - Action Required"
        }
        End = true
      }
    }
  }
}

resource "aws_cloudwatch_log_group" "escalation_workflow" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-p1-escalation-workflow"
  retention_in_days = var.log_retention_days
}

resource "aws_sfn_state_machine" "p1_escalation" {
  name       = "${local.name_prefix}-p1-escalation-workflow"
  type       = "STANDARD" # waits 5 minutes: Express workflows are for short runs
  role_arn   = aws_iam_role.escalation_workflow.arn
  definition = jsonencode(local.escalation_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.escalation_workflow.arn}:*"
    include_execution_data = true
    level                  = "ERROR" # only failed steps: cheap, and what you need to debug
  }

  # AWS checks the role can write logs when the workflow is created,
  # so the role's policy must exist first.
  depends_on = [aws_iam_role_policy.escalation_workflow]
}

# --- Role the workflow runs as ---
data "aws_iam_policy_document" "escalation_workflow_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    # Only Step Functions in this account may use the role (confused-deputy protection).
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "escalation_workflow" {
  name               = "${local.name_prefix}-p1-escalation-workflow-role"
  assume_role_policy = data.aws_iam_policy_document.escalation_workflow_trust.json
}

data "aws_iam_policy_document" "escalation_workflow" {
  statement {
    sid       = "ReadOneIncident"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.incidents.arn]
  }
  statement {
    sid       = "SendEscalationEmail"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.p1_escalation.arn]
  }
  # Step Functions log delivery uses these account-level APIs; AWS documents
  # that they don't support resource-level permissions, hence "*".
  statement {
    sid = "WriteWorkflowLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "escalation_workflow" {
  name   = "escalation-workflow"
  role   = aws_iam_role.escalation_workflow.id
  policy = data.aws_iam_policy_document.escalation_workflow.json
}

# ---------------------------------------------------------------------------
# SQS: dead-letter queue for events EventBridge could not deliver
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "p1_alerts_dlq" {
  name                      = "${local.name_prefix}-p1-alerts-dlq"
  message_retention_seconds = 1209600 # 14 days, the SQS maximum
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "p1_alerts_dlq" {
  statement {
    sid       = "AllowOnlyTheP1RuleToSend"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.p1_alerts_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.p1_alert.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "p1_alerts_dlq" {
  queue_url = aws_sqs_queue.p1_alerts_dlq.id
  policy    = data.aws_iam_policy_document.p1_alerts_dlq.json
}

# ---------------------------------------------------------------------------
# EventBridge: custom bus + P1 rule (decision 7: filter in the rule, not in code)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_bus" "incidents" {
  name = "${local.name_prefix}-events"
}

resource "aws_cloudwatch_event_rule" "p1_alert" {
  name           = "${local.name_prefix}-p1-alert-rule"
  description    = "New P1 incidents start the escalation workflow"
  event_bus_name = aws_cloudwatch_event_bus.incidents.name
  event_pattern = jsonencode({
    source        = ["cloudops.incidents"]
    "detail-type" = ["IncidentCreated"]
    detail        = { severity = ["P1"] }
  })
}

resource "aws_cloudwatch_event_target" "p1_to_workflow" {
  rule           = aws_cloudwatch_event_rule.p1_alert.name
  event_bus_name = aws_cloudwatch_event_bus.incidents.name
  target_id      = "start-p1-escalation"
  arn            = aws_sfn_state_machine.p1_escalation.arn
  role_arn       = aws_iam_role.eventbridge_to_workflow.arn

  # Pass only what the workflow needs. Placeholders are quoted (they are strings).
  # A heredoc, not jsonencode(): jsonencode would escape < and > as < >.
  input_transformer {
    input_paths = {
      incidentId = "$.detail.incidentId"
      title      = "$.detail.title"
      location   = "$.detail.location"
    }
    input_template = <<-EOT
      {"incidentId": "<incidentId>", "title": "<title>", "location": "<location>"}
    EOT
  }

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.p1_alerts_dlq.arn
  }
}

# --- Role EventBridge uses to start the workflow (bug 8: check it on every review) ---
data "aws_iam_policy_document" "eventbridge_to_workflow_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "eventbridge_to_workflow" {
  name               = "${local.name_prefix}-eventbridge-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_to_workflow_trust.json
}

data "aws_iam_policy_document" "eventbridge_to_workflow" {
  statement {
    sid       = "StartEscalationOnly"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.p1_escalation.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_to_workflow" {
  name   = "start-escalation-workflow"
  role   = aws_iam_role.eventbridge_to_workflow.id
  policy = data.aws_iam_policy_document.eventbridge_to_workflow.json
}

# ---------------------------------------------------------------------------
output "event_bus_name" {
  value = aws_cloudwatch_event_bus.incidents.name
}

output "escalation_workflow_arn" {
  value = aws_sfn_state_machine.p1_escalation.arn
}
