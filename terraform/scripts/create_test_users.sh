#!/usr/bin/env bash
# Creates the three CloudOps test users in the Terraform-managed user pool.
# - Emails are made up (no inbox needed): marked verified, no email is sent.
# - Passwords are typed here, never written to a file, the screen or Terraform state.
# Safe to run again: an existing user is kept, only the password and group are set.
set -euo pipefail

POOL_ID=$(terraform -chdir="$HOME/cloudops-terraform" output -raw cognito_user_pool_id)
echo "User pool: $POOL_ID"
echo "Password rules: at least 8 characters, with upper case, lower case, a number and a symbol."
echo

create_user() {
  local email="$1" group="$2"
  echo "== $email ${group:+(group: $group)}"

  if aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --username "$email" >/dev/null 2>&1; then
    echo "   already exists, keeping it"
  else
    aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username "$email" \
      --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
      --message-action SUPPRESS >/dev/null
    echo "   created"
  fi

  while true; do
    read -rsp "   Password for $email: " PW1; echo
    read -rsp "   Type it again: " PW2; echo
    if [[ "$PW1" != "$PW2" ]]; then echo "   They don't match, try again."; continue; fi
    # The password goes to the AWS CLI in a private temporary JSON file (readable
    # only by you, deleted straight after), not as a command-line argument.
    REQ=$(mktemp); chmod 600 "$REQ"
    PW="$PW1" POOL="$POOL_ID" U="$email" jq -n \
      '{UserPoolId: env.POOL, Username: env.U, Password: env.PW, Permanent: true}' > "$REQ"
    if aws cognito-idp admin-set-user-password --cli-input-json "file://$REQ"; then
      rm -f "$REQ"
      echo "   password set"
      break
    fi
    rm -f "$REQ"
    echo "   AWS refused that password (see the message above). Try another."
  done
  unset PW1 PW2

  if [[ -n "$group" ]]; then
    aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL_ID" --username "$email" --group-name "$group"
    echo "   added to $group"
  fi
  echo
}

create_user "manager1@cloudops-test.com"  "Managers"
create_user "engineer1@cloudops-test.com" "FieldEngineers"
create_user "viewers@cloudops-test.com"   ""   # view-only: no group on purpose

echo "== Result"
aws cognito-idp list-users --user-pool-id "$POOL_ID" \
  --query 'Users[].{user:Attributes[?Name==`email`]|[0].Value,status:UserStatus,enabled:Enabled}' --output table
for g in Managers FieldEngineers Admins; do
  printf "%-15s " "$g:"
  aws cognito-idp list-users-in-group --user-pool-id "$POOL_ID" --group-name "$g" \
    --query 'Users[].Attributes[?Name==`email`].Value[]' --output text
done
