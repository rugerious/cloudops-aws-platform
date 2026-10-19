# Sprint 11: AI triage with Amazon Bedrock.
#
#   create-incident --IncidentCreated--> event bus --rule (every severity)--> ai-triage Lambda
#                                                                               |
#                         Bedrock (Claude, EU inference profile) <-------------+
#                                                                               |
#                         incident.aiSuggestion = {severity, summary, reason} <-+
#
# The AI suggests, a human decides: the dashboard shows the suggestion and a
# manager can apply it through the existing PATCH route (which checks the role).

variable "bedrock_model_id" {
  description = "Bedrock inference profile for AI triage. eu. = the request stays in EU regions."
  type        = string
  default     = "eu.anthropic.claude-haiku-5-5" # small, fast and cheap: triage is a short task
}

resource "aws_cloudwatch_event_rule" "ai_triage" {
  name           = "${local.name_prefix}-ai-triage-rule"
  description    = "Every new incident gets an AI severity suggestion"
  event_bus_name = aws_cloudwatch_event_bus.incidents.name
  event_pattern = jsonencode({
    source        = ["cloudops.incidents"]
    "detail-type" = ["IncidentCreated"]
  })
}

resource "aws_cloudwatch_event_target" "ai_triage" {
  rule           = aws_cloudwatch_event_rule.ai_triage.name
  event_bus_name = aws_cloudwatch_event_bus.incidents.name
  target_id      = "ai-triage"
  arn            = aws_lambda_function.this["ai-triage"].arn

  # A suggestion is only useful while the incident is new: give up after 1 hour.
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }
}

# Only THIS rule on THIS bus may start the function.
resource "aws_lambda_permission" "ai_triage_from_events" {
  statement_id  = "AllowEventBridgeAiTriage"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this["ai-triage"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ai_triage.arn
}
