# GitHub Actions -> AWS without stored keys (OIDC).
# GitHub gives each workflow run a short-lived signed token; AWS trusts tokens
# from this repo only, and swaps them for 1-hour credentials of ONE role:
#   - plan role : any pull request in this repo. READ-ONLY (+ the state lock file).
#   - apply role: only jobs in the GitHub environment "production", which only
#                 the main branch may use and which waits for a human approval.
# Nothing to rotate, nothing to leak: there is no AWS key anywhere in GitHub.

variable "github_repo" {
  description = "owner/name of the GitHub repository allowed to deploy"
  type        = string
  default     = "rugerious/cloudops-aws-platform"
}

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  state_bucket     = "cloudops-tfstate-xyzw05" # same as backend.tf (backend blocks can't use variables)
}

# One per account per URL. AWS validates GitHub's certificate itself,
# so no thumbprint is needed (AWS provider 6.x).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# Trust policy shared shape: right provider, right audience, right "sub" (who/where).
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan  = "repo:${var.github_repo}:pull_request"
    apply = "repo:${var.github_repo}:environment:production"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# ---------------------------------------------------------------------------
# PLAN role: can look at everything, change nothing (except taking the state lock)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "github_plan" {
  name               = "${local.name_prefix}-github-plan"
  assume_role_policy = data.aws_iam_policy_document.github_trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan_lock" {
  statement {
    sid       = "TakeAndReleaseStateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/cloudops/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "github_plan_lock" {
  name   = "state-lock"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan_lock.json
}

# ---------------------------------------------------------------------------
# APPLY role: can build everything this project builds.
# PowerUserAccess = all services except IAM/Organizations; IAM is added back
# only for this project's own roles/policies (names starting cloudops-prod-)
# and the GitHub OIDC provider.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "github_apply" {
  name               = "${local.name_prefix}-github-apply"
  assume_role_policy = data.aws_iam_policy_document.github_trust["apply"].json
}

resource "aws_iam_role_policy_attachment" "github_apply_poweruser" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "github_apply_iam" {
  statement {
    sid     = "ManageThisProjectsIam"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-*",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }
  statement {
    sid       = "ReadAnyIam" # Terraform reads attached AWS managed policies etc.
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_apply_iam" {
  name   = "project-iam"
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.github_apply_iam.json
}

output "github_plan_role_arn" {
  value = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  value = aws_iam_role.github_apply.arn
}
