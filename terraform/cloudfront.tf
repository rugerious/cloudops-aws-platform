# Dashboard hosting: browser -> CloudFront (HTTPS, WAF) -> private S3 bucket.
# Copied from the console distribution EA8NN9PO03IWV (14 Oct inventory):
# OAC signing, default root object login.html, CachingOptimized, HTTPS redirect,
# WAF with the same three AWS managed rule groups.
# Changes:
#   - WAF web ACL gets a real name (was "CreatedByCloudFront-316823a1")
#   - security response headers added (HSTS, nosniff, X-Frame-Options, referrer policy)
#   - dashboard bucket policy also refuses non-HTTPS requests
# Also here, because they need the new CloudFront domain:
#   - attachments bucket CORS (bug 13: without it, browser uploads fail)
#
# NOT in Terraform: the free flat-rate pricing plan. It is chosen once in the
# console after this step (see the step instructions).

# ---------------------------------------------------------------------------
# WAF (must live in us-east-1 for CloudFront -> aliased provider)
# ---------------------------------------------------------------------------
locals {
  waf_managed_rule_groups = [
    "AWSManagedRulesAmazonIpReputationList", # known bad IPs, bots
    "AWSManagedRulesCommonRuleSet",          # OWASP-style common attacks
    "AWSManagedRulesKnownBadInputsRuleSet",  # e.g. Log4j-style payloads
  ]
}

resource "aws_wafv2_web_acl" "dashboard" {
  provider    = aws.us_east_1
  name        = "${local.name_prefix}-dashboard-waf"
  description = "Protects the CloudOps dashboard distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups
    content {
      name     = "AWS-${rule.value}"
      priority = rule.key # 0, 1, 2 (same order as the console ACL)

      override_action {
        none {} # use the rule group's own block/count actions
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "AWS-${rule.value}"
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${local.name_prefix}-dashboard-waf"
  }
}

# ---------------------------------------------------------------------------
# CloudFront
# ---------------------------------------------------------------------------
# AWS managed policies, looked up by name instead of hardcoding their IDs.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

# Origin Access Control: CloudFront signs every request to S3 (SigV4),
# so the bucket can stay fully private.
resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "${local.name_prefix}-dashboard-oac"
  description                       = "CloudFront access to the private dashboard bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  dashboard_origin_id = "dashboard-s3"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  comment             = "${local.name_prefix} dashboard"
  default_root_object = "login.html"
  is_ipv6_enabled     = true
  http_version        = "http2"
  price_class         = "PriceClass_All"
  web_acl_id          = aws_wafv2_web_acl.dashboard.arn

  origin {
    origin_id                = local.dashboard_origin_id
    domain_name              = aws_s3_bucket.this["dashboard"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    target_origin_id           = local.dashboard_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"] # static site: read-only
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net, no custom domain
  }
}

# ---------------------------------------------------------------------------
# Dashboard bucket policy: only THIS distribution may read; HTTPS only
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "dashboard_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["dashboard"].arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.dashboard.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.this["dashboard"].arn,
      "${aws_s3_bucket.this["dashboard"].arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket     = aws_s3_bucket.this["dashboard"].id
  policy     = data.aws_iam_policy_document.dashboard_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Attachments CORS (bug 13): the browser PUTs photos straight to S3 with a
# presigned URL, so S3 must accept PUT from the dashboard's origin.
# ---------------------------------------------------------------------------
locals {
  dashboard_origin = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
}

resource "aws_s3_bucket_cors_configuration" "attachments" {
  bucket = aws_s3_bucket.this["attachments"].id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = [local.dashboard_origin]
    allowed_headers = ["Content-Type"]
    max_age_seconds = 3000
  }
}

# ---------------------------------------------------------------------------
output "dashboard_url" {
  value = local.dashboard_origin
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.dashboard.id
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.dashboard.arn
}
