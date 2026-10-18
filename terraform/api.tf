# HTTP API: browser -> API Gateway (JWT check) -> Lambda.
# Same 10 routes, JWT authorizer on every route, payload format 2.0 and
# CORS locked to the dashboard origin, as in cloudops-dev-api (14 Oct inventory).
# Changes:
#   - one integration per function (the console API had 10 for 9 functions)
#   - bug 26: one invoke permission per ROUTE, scoped to this API + method + path
#     (the console left permissions for deleted APIs and over-broad paths)
#   - stage throttling (protects the Lambdas and the bill from floods)
#   - access logs to CloudWatch (30-day retention): who called what, status, latency

locals {
  # route key => function that handles it (decision 1: one route per state change)
  api_routes = {
    "POST /incidents"                                        = "create-incident"
    "GET /incidents"                                         = "list-incidents"
    "GET /incidents/{incidentId}"                            = "get-incident"
    "PATCH /incidents/{incidentId}"                          = "update-incident"
    "POST /incidents/{incidentId}/acknowledge"               = "acknowledge-incident"
    "POST /incidents/{incidentId}/resolve"                   = "incident-lifecycle"
    "POST /incidents/{incidentId}/reopen"                    = "incident-lifecycle"
    "POST /incidents/{incidentId}/close"                     = "close-incident"
    "POST /incidents/{incidentId}/attachments"               = "get-upload-url"
    "GET /incidents/{incidentId}/attachments/{attachmentId}" = "get-attachment-url"
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  # The browser may only call the API from the dashboard's address.
  cors_configuration {
    allow_origins     = [local.dashboard_origin]
    allow_methods     = ["GET", "POST", "PATCH", "OPTIONS"]
    allow_headers     = ["content-type", "authorization"]
    allow_credentials = false
    max_age           = 300 # browser may reuse a preflight answer for 5 minutes
  }
}

# Every request must carry a valid Cognito ID token for OUR app client.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http.id
  name             = "${local.name_prefix}-cognito-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = "https://${aws_cognito_user_pool.users.endpoint}"
    audience = [aws_cognito_user_pool_client.public.id]
  }
}

# One Lambda integration per function (incident-lifecycle serves two routes).
resource "aws_apigatewayv2_integration" "lambda" {
  for_each               = local.lambda_functions
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.this[each.key].invoke_arn
  payload_format_version = "2.0" # the code reads requestContext.authorizer.jwt.claims
}

resource "aws_apigatewayv2_route" "this" {
  for_each           = local.api_routes
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.lambda[each.value].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# Bug 26: exactly one permission per route, for this API, this method, this path.
resource "aws_lambda_permission" "api" {
  for_each      = local.api_routes
  statement_id  = "AllowApi-${trim(replace(each.key, "/[^a-zA-Z0-9]+/", "-"), "-")}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.value].function_name
  principal     = "apigateway.amazonaws.com"
  # e.g. arn:aws:execute-api:eu-west-2:<acct>:<api-id>/*/POST/incidents/{incidentId}/close
  source_arn = "${aws_apigatewayv2_api.http.execution_arn}/*/${replace(each.key, " ", "")}"
}

# ---------------------------------------------------------------------------
# Stage: $default, auto-deploy, throttling, access logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = 20 # requests per second, steady
    throttling_burst_limit = 50 # short spikes
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      latencyMs      = "$context.responseLatency"
      user           = "$context.authorizer.claims.email"
      authError      = "$context.authorizer.error"
      integrationErr = "$context.integrationErrorMessage"
    })
  }
}

output "api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}
