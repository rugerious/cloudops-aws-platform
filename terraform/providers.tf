# Main provider: everything in London.
provider "aws" {
  region = var.region

  # Added to every resource automatically -> easy to find and to cost.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Second provider for the few things AWS only allows in us-east-1:
# the WAF web ACL that protects CloudFront.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
