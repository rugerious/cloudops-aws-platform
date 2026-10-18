# Sign-in for the dashboard and the API (JWT authorizer).
# Copied from cloudops-dev-users (14 Oct inventory) with three deliberate changes:
#   1. Only admins create users (bug 25: self sign-up was open).
#   2. The app client keeps only the flow the dashboard really uses
#      (USER_PASSWORD_AUTH + refresh); SRP, USER_AUTH, OAuth "code" flow,
#      the https://localhost callback and the Cognito domain are dropped (unused).
#   3. Password recovery by verified email only (no SMS is configured).
#
# Users are NOT created here: their passwords would end up in the state file.
# They are created with the AWS CLI in the testing step.

resource "aws_cognito_user_pool" "users" {
  name = "${local.name_prefix}-users" # cloudops-prod-users

  # Sign in with the email address; Cognito sends a code to verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true # (1) no self sign-up
  }

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting { # (3)
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Email is a required attribute, as in the console pool.
  # The constraints block stops Terraform wanting to recreate the pool on every plan.
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT" # free, low daily limit: fine for a demo
  }

  mfa_configuration   = "OFF"
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE" # AWS refuses to delete the pool (and its users) while ACTIVE
}

# Public client for the browser (a single-page app cannot keep a secret).
resource "aws_cognito_user_pool_client" "public" {
  name         = "${local.name_prefix}-public-client"
  user_pool_id = aws_cognito_user_pool.users.id

  generate_secret = false

  explicit_auth_flows = [       # (2)
    "ALLOW_USER_PASSWORD_AUTH", # login.html: InitiateAuth with USER_PASSWORD_AUTH
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 5
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
  auth_session_validity = 3 # minutes to finish a challenge (e.g. NEW_PASSWORD_REQUIRED)

  prevent_user_existence_errors = "ENABLED" # same error for "no such user" and "wrong password"
  enable_token_revocation       = true
}

# Role groups. Their names appear in the token's cognito:groups claim,
# which the Lambdas check (e.g. only Managers/Admins may close).
resource "aws_cognito_user_group" "roles" {
  for_each = {
    Admins         = "Full access, including data repair"
    Managers       = "Sign off (close) and reopen incidents, change severity"
    FieldEngineers = "Acknowledge, work on and resolve incidents, upload photos"
  }

  user_pool_id = aws_cognito_user_pool.users.id
  name         = each.key
  description  = each.value
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.users.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.public.id
}

# Used later by the API Gateway JWT authorizer.
output "cognito_issuer_url" {
  value = "https://${aws_cognito_user_pool.users.endpoint}"
}
