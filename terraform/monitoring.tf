# Platform health alarms -> email. Separate from the P1 escalation topic:
# P1 emails are about INCIDENTS (business), these are about the SYSTEM itself.
#
# Four alarms, chosen so that any silent failure in the request path or the
# escalation path is noticed. Four alarms stay inside the CloudWatch free tier
# (10 standard alarms per month).
#   1. Any Lambda error            (code crashed: e.g. bug 10 Decimal, bug 11 truncated file)
#   2. API returning 5xx           (users see errors)
#   3. Message in the P1 DLQ       (an escalation could not even start)
#   4. Escalation workflow failed  (a P1 email may not have been sent)

resource "aws_sns_topic" "ops_alerts" {
  name = "${local.name_prefix}-ops-alerts"
}

# Same address as the P1 emails (terraform.tfvars). AWS sends a NEW
# confirmation email for this topic: it must be clicked too.
resource "aws_sns_topic_subscription" "ops_alerts_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_defaults = {
    period              = 300 # 5 minutes
    evaluation_periods  = 1
    comparison_operator = "GreaterThanOrEqualToThreshold"
    treat_missing_data  = "notBreaching" # no traffic = healthy, not "insufficient data"
  }
}

# 1. Lambda errors, all functions in the region together (one alarm, not nine).
#    "Errors" counts crashes and timeouts only; a deliberate 400/403/409 reply is not an error.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-lambda-errors"
  alarm_description   = "A CloudOps Lambda crashed or timed out. Check its log group: /aws/lambda/${local.name_prefix}-*"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  threshold           = 1
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  comparison_operator = local.alarm_defaults.comparison_operator
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# 2. API 5xx: 3 or more server errors in 5 minutes (one stray error is not paged twice:
#    a Lambda crash already raises alarm 1).
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name_prefix}-api-5xx"
  alarm_description   = "The API returned 3+ server errors in 5 minutes. Check /aws/apigateway/${local.name_prefix}-api (integrationErr field)."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.http.id }
  statistic           = "Sum"
  threshold           = 3
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  comparison_operator = local.alarm_defaults.comparison_operator
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# 3. Anything in the DLQ means EventBridge could not start an escalation.
resource "aws_cloudwatch_metric_alarm" "p1_dlq" {
  alarm_name          = "${local.name_prefix}-p1-dlq-not-empty"
  alarm_description   = "A P1 event could not be delivered to the escalation workflow. Read the message in ${aws_sqs_queue.p1_alerts_dlq.name}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.p1_alerts_dlq.name }
  statistic           = "Maximum"
  threshold           = 1
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  comparison_operator = local.alarm_defaults.comparison_operator
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# 4. The escalation workflow itself failed (e.g. lost DynamoDB or SNS permission).
resource "aws_cloudwatch_metric_alarm" "escalation_failed" {
  alarm_name          = "${local.name_prefix}-escalation-workflow-failed"
  alarm_description   = "A P1 escalation run failed: the escalation email may not have been sent. Check the execution in Step Functions."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.p1_escalation.arn }
  statistic           = "Sum"
  threshold           = 1
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  comparison_operator = local.alarm_defaults.comparison_operator
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.lambda_errors.alarm_name,
    aws_cloudwatch_metric_alarm.api_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.p1_dlq.alarm_name,
    aws_cloudwatch_metric_alarm.escalation_failed.alarm_name,
  ]
}
