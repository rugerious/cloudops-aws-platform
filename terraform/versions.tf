# Which Terraform and which providers this project needs.
# Terraform >= 1.10 is required for S3-native state locking (use_lockfile).
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive" # zips the Lambda code
      version = "~> 2.0"
    }
  }
}
