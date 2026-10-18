# Facts read from AWS (read-only) and names built once, used everywhere.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}" # e.g. cloudops-prod
  account_id  = data.aws_caller_identity.current.account_id
}
