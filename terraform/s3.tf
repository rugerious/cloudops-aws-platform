# The two buckets of the system. Settings copied from the console-built
# cloudops-dev-* buckets (14 Oct inventory), plus a "HTTPS only" policy on attachments.
#
# Added in later steps (they need resources that don't exist yet):
#   - attachments CORS rule  -> needs the new CloudFront domain (Step: CloudFront)
#   - dashboard bucket policy -> lets only the new CloudFront read it (Step: CloudFront)
#   - dashboard files         -> need the new API URL and Cognito IDs (Step: dashboard)

variable "bucket_suffix" {
  description = "Suffix that makes S3 bucket names globally unique"
  type        = string
  default     = "xyzw05"
}

locals {
  bucket_names = {
    attachments = "${local.name_prefix}-attachments-${var.bucket_suffix}" # cloudops-prod-attachments-xyzw05
    dashboard   = "${local.name_prefix}-dashboard-${var.bucket_suffix}"   # cloudops-prod-dashboard-xyzw05
  }
}

# ---------------------------------------------------------------------------
# Both buckets: same baseline (for_each = one block, two buckets)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = local.bucket_names
  bucket   = each.value
}

# Nothing in either bucket may ever be public.
resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ACLs disabled: the bucket owner owns every object; access only via policies.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Encrypted at rest with S3-managed keys; customer-provided keys (SSE-C) refused.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

# ---------------------------------------------------------------------------
# Attachments only
# ---------------------------------------------------------------------------

# Decision 10: day 30 -> Standard-IA, day 90 -> Glacier Instant Retrieval
# (photos still open instantly), never deleted (evidence),
# unfinished multipart uploads cleaned after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "attachments" {
  bucket = aws_s3_bucket.this["attachments"].id

  rule {
    id     = "attachments-cost-tiering"
    status = "Enabled"

    filter {
      prefix = "incidents/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# NEW vs console: refuse any request that isn't HTTPS (presigned URLs use HTTPS anyway).
data "aws_iam_policy_document" "attachments_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.this["attachments"].arn,
      "${aws_s3_bucket.this["attachments"].arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "attachments" {
  bucket = aws_s3_bucket.this["attachments"].id
  policy = data.aws_iam_policy_document.attachments_tls_only.json

  # Block Public Access must exist first, or AWS may reject the policy call.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

output "bucket_names" {
  value = { for k, b in aws_s3_bucket.this : k => b.id }
}
