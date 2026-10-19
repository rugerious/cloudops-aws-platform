# The 9 API functions (+ ai-triage, Sprint 11, started by EventBridge). Code = exactly what runs today (downloaded by the
# 14 Oct inventory) + one change: create-incident reads EVENT_BUS_NAME from
# its environment instead of the hardcoded "cloudops-dev-events".
#
# Changes vs the console:
#   - ONE IAM ROLE PER FUNCTION (bug 24: five functions shared one role)
#   - each role may only write to its own log group (no CreateLogGroup)
#   - log groups created here with 30-day retention (9 of 10 never expired)
#   - timeout 10 s (was 3): geocoding + cold start can get close to 3 s;
#     you only pay for the time actually used
#
# API Gateway invoke permissions are added in Step 07 (they need the API ID).

locals {
  table_arn       = aws_dynamodb_table.incidents.arn
  attachments_arn = aws_s3_bucket.this["attachments"].arn
  geocode_arn     = "arn:aws:geo-places:${var.region}::provider/default"

  # Sprint 11 AI triage. An "eu." inference profile may run the model in any EU
  # region, so the role needs the profile AND the model in eu-* regions.
  bedrock_profile_arn = "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${var.bedrock_model_id}"
  bedrock_model_arn   = "arn:aws:bedrock:eu-*::foundation-model/${trimprefix(var.bedrock_model_id, "eu.")}*"

  # Functions that need more than the default 10 s (a model reply takes a few seconds).
  lambda_timeouts = { "ai-triage" = 30 }

  # One entry per function: its environment variables and its permissions.
  # Every action listed here is a call the function's code really makes.
  lambda_functions = {
    "create-incident" = {
      env = {
        TABLE_NAME     = aws_dynamodb_table.incidents.name
        EVENT_BUS_NAME = aws_cloudwatch_event_bus.incidents.name
      }
      statements = [
        { sid = "SaveNewIncident", actions = ["dynamodb:PutItem"], resources = [local.table_arn] },
        { sid = "PublishIncidentCreated", actions = ["events:PutEvents"], resources = [aws_cloudwatch_event_bus.incidents.arn] },
        { sid = "GeocodeLocation", actions = ["geo-places:Geocode"], resources = [local.geocode_arn] },
      ]
    }
    "get-incident" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        { sid = "ReadOneIncident", actions = ["dynamodb:GetItem"], resources = [local.table_arn] },
      ]
    }
    "list-incidents" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        # Only the status index, never the whole table (no Scan).
        { sid = "QueryByStatus", actions = ["dynamodb:Query"], resources = ["${local.table_arn}/index/status-createdAt-index"] },
      ]
    }
    "update-incident" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        { sid = "UpdateIncident", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources = [local.table_arn] },
        { sid = "GeocodeLocation", actions = ["geo-places:Geocode"], resources = [local.geocode_arn] },
      ]
    }
    "acknowledge-incident" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        { sid = "AcknowledgeIncident", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources = [local.table_arn] },
      ]
    }
    "close-incident" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        { sid = "CloseIncident", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources = [local.table_arn] },
      ]
    }
    "incident-lifecycle" = {
      env = { TABLE_NAME = aws_dynamodb_table.incidents.name }
      statements = [
        { sid = "ResolveOrReopenIncident", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources = [local.table_arn] },
      ]
    }
    "get-upload-url" = {
      env = {
        TABLE_NAME         = aws_dynamodb_table.incidents.name
        ATTACHMENTS_BUCKET = aws_s3_bucket.this["attachments"].id
      }
      statements = [
        { sid = "RecordAttachment", actions = ["dynamodb:UpdateItem", "dynamodb:GetItem"], resources = [local.table_arn] },
        # Presigned PUT URLs carry the function's permission: uploads only under incidents/.
        { sid = "SignUploadUrl", actions = ["s3:PutObject"], resources = ["${local.attachments_arn}/incidents/*"] },
      ]
    }
    "get-attachment-url" = {
      env = {
        TABLE_NAME         = aws_dynamodb_table.incidents.name
        ATTACHMENTS_BUCKET = aws_s3_bucket.this["attachments"].id # same name as get-upload-url
      }
      statements = [
        { sid = "ReadIncidentAttachments", actions = ["dynamodb:GetItem"], resources = [local.table_arn] },
        # ListBucket deliberately NOT granted (bug 14).
        { sid = "SignDownloadUrl", actions = ["s3:GetObject"], resources = ["${local.attachments_arn}/incidents/*"] },
      ]
    }
    # Not behind the API: started by EventBridge for every new incident (ai.tf).
    "ai-triage" = {
      env = {
        TABLE_NAME = aws_dynamodb_table.incidents.name
        MODEL_ID   = var.bedrock_model_id
      }
      statements = [
        # Writes ONLY the aiSuggestion field (the code never sets severity).
        { sid = "SaveSuggestion", actions = ["dynamodb:UpdateItem"], resources = [local.table_arn] },
        { sid = "AskTheModel", actions = ["bedrock:InvokeModel"], resources = [local.bedrock_profile_arn, local.bedrock_model_arn] },
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Package: one zip per function, rebuilt only when its code changes
# ---------------------------------------------------------------------------
data "archive_file" "lambda" {
  for_each    = local.lambda_functions
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"
  excludes    = ["__pycache__"]
}

# ---------------------------------------------------------------------------
# Logs: created by Terraform (with retention) BEFORE the function first runs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.lambda_functions
  name              = "/aws/lambda/${local.name_prefix}-${each.key}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# One role per function
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each           = local.lambda_functions
  name               = "${local.name_prefix}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda" {
  for_each = local.lambda_functions

  # The function's own permissions (from the map above).
  dynamic "statement" {
    for_each = each.value.statements
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }

  # Write logs to its own log group only. No logs:CreateLogGroup: if the
  # group is ever deleted, logging stops instead of silently recreating a
  # group that never expires.
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.lambda_functions
  name     = "${each.key}-permissions"
  role     = aws_iam_role.lambda[each.key].id
  policy   = data.aws_iam_policy_document.lambda[each.key].json
}

# ---------------------------------------------------------------------------
# The functions
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "this" {
  for_each = local.lambda_functions

  function_name = "${local.name_prefix}-${each.key}" # e.g. cloudops-prod-create-incident
  role          = aws_iam_role.lambda[each.key].arn

  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256

  runtime       = "python3.14"
  architectures = ["arm64"] # decision 11: Graviton, ~20% cheaper
  handler       = "lambda_function.lambda_handler"
  memory_size   = 128
  timeout       = lookup(local.lambda_timeouts, each.key, 10)

  environment {
    variables = each.value.env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda[each.key].name
  }

  # The role must be able to write logs before the first invocation.
  depends_on = [aws_iam_role_policy.lambda]
}

output "lambda_function_names" {
  value = [for f in aws_lambda_function.this : f.function_name]
}
