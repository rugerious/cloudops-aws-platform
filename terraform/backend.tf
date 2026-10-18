# Where Terraform keeps its state file (the map: code <-> real AWS resources).
# The bucket was created by hand once (bootstrap) with versioning, encryption
# and Block Public Access. Backend blocks cannot use variables, so values are literal.
terraform {
  backend "s3" {
    bucket       = "cloudops-tfstate-xyzw05"
    key          = "cloudops/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true # lock file in the same bucket: stops two runs at once
  }
}
