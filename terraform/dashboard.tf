# The dashboard files: login.html + dashboard.html, exactly as they run today
# (14 Oct inventory) with the environment-specific values replaced by
# placeholders that Terraform fills in from the resources it built:
#   __API_BASE__           -> the new API URL
#   __COGNITO_CLIENT_ID__  -> the new app client
#   __AWS_REGION__         -> eu-west-2
#   __ENV_LABEL__ / __REGION_LABEL__ -> footer text "CLOUDOPS-PROD · EU-WEST-2"
# So the files can never point at the wrong API or client.

locals {
  dashboard_values = {
    "__API_BASE__"          = aws_apigatewayv2_api.http.api_endpoint
    "__COGNITO_CLIENT_ID__" = aws_cognito_user_pool_client.public.id
    "__AWS_REGION__"        = var.region
    "__ENV_LABEL__"         = upper(local.name_prefix)
    "__REGION_LABEL__"      = upper(var.region)
  }

  # Read each file and replace every placeholder (one replace() per value).
  dashboard_files = {
    for f in ["login.html", "dashboard.html"] : f => replace(replace(replace(replace(replace(
      file("${path.module}/dashboard_src/${f}"),
      "__API_BASE__", local.dashboard_values["__API_BASE__"]),
      "__COGNITO_CLIENT_ID__", local.dashboard_values["__COGNITO_CLIENT_ID__"]),
      "__AWS_REGION__", local.dashboard_values["__AWS_REGION__"]),
      "__ENV_LABEL__", local.dashboard_values["__ENV_LABEL__"]),
    "__REGION_LABEL__", local.dashboard_values["__REGION_LABEL__"])
  }
}

resource "aws_s3_object" "dashboard" {
  for_each = local.dashboard_files

  bucket       = aws_s3_bucket.this["dashboard"].id
  key          = each.key
  content      = each.value
  content_type = "text/html; charset=utf-8"

  # "no-cache" = browsers and CloudFront must check for a newer version
  # (a cheap 304 when nothing changed). A new deploy is therefore visible
  # straight away, without a CloudFront invalidation: this closes the
  # "old dashboard still showing" problem (tracker: Load more never tested).
  cache_control = "no-cache"

  lifecycle {
    # Refuse to upload a file that still contains a placeholder.
    precondition {
      condition     = length(regexall("__[A-Z_]+__", each.value)) == 0
      error_message = "${each.key} still contains an unreplaced __PLACEHOLDER__."
    }
  }

  # The bucket policy (Step 07) must exist so CloudFront can read the files.
  depends_on = [aws_s3_bucket_policy.dashboard]
}

output "dashboard_login_url" {
  value = "${local.dashboard_origin}/login.html"
}
