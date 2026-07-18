#!/usr/bin/env bash
# Deploy the native SCP-only cost quarantine by default. Optional multi-region
# active remediation is created only with ENABLE_REMEDIATION=true: it deploys
# the Test cross-account role, the management forwarding rule, and a StackSet
# of per-region state machines. Zero Lambda functions.
#
# Usage: ./deploy.sh <test-account-id> <prod-account-id> <notification-email> [test-sso-profile]
# Required environment:
#   AWS_PROFILE or MANAGEMENT_PROFILE  LandingZoneAdmin SSO profile
# Optional environment:
#   ENABLE_REMEDIATION                 false (default) or true
#   TEST_PROFILE                       alternative to the optional fourth argument
#   REGION                             quarantine stack Region (default us-east-1)
#   IDENTITY_REGION                    IdC stack Region (default eu-central-1)
#   TEST_QUARANTINE_THRESHOLD          default 50 USD, FORECASTED
#   PROD_QUARANTINE_THRESHOLD          default 50 USD, ACTUAL
#   REMEDIATION_REGIONS                default us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 3 && $# -le 4 ]] ||
  fail "Usage: $0 <test-account-id> <prod-account-id> <notification-email> [test-sso-profile]"

TEST_ACCOUNT_ID="$1"
PROD_ACCOUNT_ID="$2"
NOTIFICATION_EMAIL="$3"
TEST_PROFILE="${4:-${TEST_PROFILE:-}}"
MANAGEMENT_PROFILE="${MANAGEMENT_PROFILE:-${AWS_PROFILE:-}}"
ENABLE_REMEDIATION="${ENABLE_REMEDIATION:-false}"
REGION="${REGION:-us-east-1}"
IDENTITY_REGION="${IDENTITY_REGION:-eu-central-1}"
MANAGEMENT_STACK_NAME="${STACK_NAME:-home-cost-quarantine}"
TEST_ROLE_STACK_NAME="${TEST_ROLE_STACK_NAME:-home-cost-quarantine-remediation-role}"
REGIONAL_STACKSET_NAME="${REGIONAL_STACKSET_NAME:-home-cost-quarantine-regional}"
IDENTITY_STACK_NAME="${IDENTITY_STACK_NAME:-home-idc-permission-sets}"
TEST_QUARANTINE_THRESHOLD="${TEST_QUARANTINE_THRESHOLD:-50}"
PROD_QUARANTINE_THRESHOLD="${PROD_QUARANTINE_THRESHOLD:-50}"
REMEDIATION_REGIONS="${REMEDIATION_REGIONS:-us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1}"
TEST_REMEDIATION_ROLE_NAME="${TEST_REMEDIATION_ROLE_NAME:-home-cost-quarantine-remediation}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANAGEMENT_TEMPLATE="$ROOT_DIR/cloudformation/cost-quarantine.yaml"
TEST_TEMPLATE="$ROOT_DIR/cloudformation/test-remediation-role.yaml"
REGIONAL_TEMPLATE="$ROOT_DIR/cloudformation/regional-remediation.yaml"

[[ "$TEST_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "test-account-id must be exactly 12 digits"
[[ "$PROD_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "prod-account-id must be exactly 12 digits"
[[ "$TEST_ACCOUNT_ID" != "$PROD_ACCOUNT_ID" ]] || fail "Test and Prod account IDs must be different"
[[ -n "$MANAGEMENT_PROFILE" ]] || fail "Set AWS_PROFILE or MANAGEMENT_PROFILE to LandingZoneAdmin"
[[ "$ENABLE_REMEDIATION" == "true" || "$ENABLE_REMEDIATION" == "false" ]] ||
  fail "ENABLE_REMEDIATION must be true or false"
for threshold in "$TEST_QUARANTINE_THRESHOLD" "$PROD_QUARANTINE_THRESHOLD"; do
  [[ "$threshold" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]] ||
    fail "quarantine thresholds must be numbers greater than or equal to 1"
done
if [[ "$ENABLE_REMEDIATION" == "true" && -z "$TEST_PROFILE" ]]; then
  fail "ENABLE_REMEDIATION=true requires a Test WorkloadAdmin profile as the fourth argument or TEST_PROFILE"
fi

"$ROOT_DIR/validate.sh"

read -r management_account_id management_caller_arn extra < <(
  aws sts get-caller-identity \
    --profile "$MANAGEMENT_PROFILE" \
    --region "$REGION" \
    --query '[Account,Arn]' \
    --output text
)
[[ -n "${management_account_id:-}" && -n "${management_caller_arn:-}" && -z "${extra:-}" ]] ||
  fail "could not parse management caller identity"
[[ "$management_caller_arn" == arn:aws:sts::*:assumed-role/AWSReservedSSO_LandingZoneAdmin_*/* ]] ||
  fail "management profile is not LandingZoneAdmin: $management_caller_arn"
organization_management_id="$(aws organizations describe-organization \
  --profile "$MANAGEMENT_PROFILE" \
  --region "$REGION" \
  --query 'Organization.ManagementAccountId || Organization.MasterAccountId' \
  --output text)"
[[ "$management_account_id" == "$organization_management_id" ]] ||
  fail "management profile account $management_account_id is not Organizations management account $organization_management_id"
[[ "$management_account_id" != "$TEST_ACCOUNT_ID" && "$management_account_id" != "$PROD_ACCOUNT_ID" ]] ||
  fail "management, Test, and Prod must be three distinct accounts"

account_status() {
  aws organizations list-accounts \
    --profile "$MANAGEMENT_PROFILE" \
    --region "$REGION" \
    --query "Accounts[?Id=='$1'].Status | [0]" \
    --output text
}
[[ "$(account_status "$TEST_ACCOUNT_ID")" == "ACTIVE" ]] || fail "Test account is not active in the organization"
[[ "$(account_status "$PROD_ACCOUNT_ID")" == "ACTIVE" ]] || fail "Prod account is not active in the organization"

QUARANTINE_BOUNDARY_ARN="$(aws cloudformation describe-stacks \
  --profile "$MANAGEMENT_PROFILE" \
  --region "$IDENTITY_REGION" \
  --stack-name "$IDENTITY_STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`CostQuarantineRoleBoundaryArn`].OutputValue | [0]' \
  --output text)"
[[ -n "$QUARANTINE_BOUNDARY_ARN" && "$QUARANTINE_BOUNDARY_ARN" != "None" ]] ||
  fail "identity stack '$IDENTITY_STACK_NAME' in $IDENTITY_REGION has no CostQuarantineRoleBoundaryArn output"

if [[ "$ENABLE_REMEDIATION" == "true" ]]; then
  read -r test_caller_account_id test_caller_arn test_extra < <(
    aws sts get-caller-identity \
      --profile "$TEST_PROFILE" \
      --region "$REGION" \
      --query '[Account,Arn]' \
      --output text
  )
  [[ -n "${test_caller_account_id:-}" && -n "${test_caller_arn:-}" && -z "${test_extra:-}" ]] ||
    fail "could not parse Test caller identity"
  [[ "$test_caller_account_id" == "$TEST_ACCOUNT_ID" ]] ||
    fail "Test profile resolves to $test_caller_account_id, expected $TEST_ACCOUNT_ID"
  [[ "$test_caller_arn" == arn:aws:sts::*:assumed-role/AWSReservedSSO_WorkloadAdmin_*/* ]] ||
    fail "Test profile is not WorkloadAdmin: $test_caller_arn"

  printf "Deploying Test remediation role stack '%s'...\n" "$TEST_ROLE_STACK_NAME"
  aws cloudformation deploy \
    --profile "$TEST_PROFILE" \
    --region "$REGION" \
    --stack-name "$TEST_ROLE_STACK_NAME" \
    --template-file "$TEST_TEMPLATE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
      "ManagementAccountId=$management_account_id" \
      "TestRemediationRoleName=$TEST_REMEDIATION_ROLE_NAME"
else
  printf 'Active remediation is disabled: no workload-account calls, no regional StackSet.\n'
fi

printf "Deploying management quarantine stack '%s' with remediation=%s...\n" \
  "$MANAGEMENT_STACK_NAME" "$ENABLE_REMEDIATION"
aws cloudformation deploy \
  --profile "$MANAGEMENT_PROFILE" \
  --region "$REGION" \
  --stack-name "$MANAGEMENT_STACK_NAME" \
  --template-file "$MANAGEMENT_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "TestAccountId=$TEST_ACCOUNT_ID" \
    "ProdAccountId=$PROD_ACCOUNT_ID" \
    "QuarantineRoleBoundaryArn=$QUARANTINE_BOUNDARY_ARN" \
    "NotificationEmail=$NOTIFICATION_EMAIL" \
    "TestQuarantineThreshold=$TEST_QUARANTINE_THRESHOLD" \
    "ProdQuarantineThreshold=$PROD_QUARANTINE_THRESHOLD" \
    "EnableRemediation=$ENABLE_REMEDIATION" \
    "RemediationRegions=$REMEDIATION_REGIONS" \
    "TestRemediationRoleName=$TEST_REMEDIATION_ROLE_NAME"

printf '\nManagement stack outputs:\n'
aws cloudformation describe-stacks \
  --profile "$MANAGEMENT_PROFILE" \
  --region "$REGION" \
  --stack-name "$MANAGEMENT_STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
  --output table

if [[ "$ENABLE_REMEDIATION" == "true" ]]; then
  printf '\nDeploying regional remediation StackSet "%s" to: %s\n' \
    "$REGIONAL_STACKSET_NAME" "$REMEDIATION_REGIONS"

  # Convert comma-separated regions to JSON array for --regions
  IFS=',' read -r -a region_array <<< "$REMEDIATION_REGIONS"

  template_body="$(cat "$REGIONAL_TEMPLATE")"

  # Create or update the StackSet
  if aws cloudformation describe-stack-set \
      --profile "$MANAGEMENT_PROFILE" \
      --region "$REGION" \
      --stack-set-name "$REGIONAL_STACKSET_NAME" >/dev/null 2>&1; then
    printf 'Updating existing StackSet...\n'
    aws cloudformation update-stack-set \
      --profile "$MANAGEMENT_PROFILE" \
      --region "$REGION" \
      --stack-set-name "$REGIONAL_STACKSET_NAME" \
      --template-body "$template_body" \
      --capabilities CAPABILITY_NAMED_IAM \
      --permission-model SELF_MANAGED \
      --parameters \
        "ParameterKey=TestAccountId,ParameterValue=$TEST_ACCOUNT_ID" \
        "ParameterKey=ManagementAccountId,ParameterValue=$management_account_id" \
        "ParameterKey=TestRemediationRoleName,ParameterValue=$TEST_REMEDIATION_ROLE_NAME" \
        "ParameterKey=QuarantineRoleBoundaryArn,ParameterValue=$QUARANTINE_BOUNDARY_ARN" \
      --operation-preferences \
        "RegionConcurrencyType=PARALLEL,FailureToleranceCount=0" \
      --regions "${region_array[@]}" \
      --accounts "$management_account_id" || true
  else
    printf 'Creating new StackSet...\n'
    aws cloudformation create-stack-set \
      --profile "$MANAGEMENT_PROFILE" \
      --region "$REGION" \
      --stack-set-name "$REGIONAL_STACKSET_NAME" \
      --template-body "$template_body" \
      --capabilities CAPABILITY_NAMED_IAM \
      --permission-model SELF_MANAGED \
      --parameters \
        "ParameterKey=TestAccountId,ParameterValue=$TEST_ACCOUNT_ID" \
        "ParameterKey=ManagementAccountId,ParameterValue=$management_account_id" \
        "ParameterKey=TestRemediationRoleName,ParameterValue=$TEST_REMEDIATION_ROLE_NAME" \
        "ParameterKey=QuarantineRoleBoundaryArn,ParameterValue=$QUARANTINE_BOUNDARY_ARN"

    printf 'Creating stack instances in all remediation Regions...\n'
    aws cloudformation create-stack-instances \
      --profile "$MANAGEMENT_PROFILE" \
      --region "$REGION" \
      --stack-set-name "$REGIONAL_STACKSET_NAME" \
      --regions "${region_array[@]}" \
      --accounts "$management_account_id" \
      --operation-preferences \
        "RegionConcurrencyType=PARALLEL,FailureToleranceCount=0"
  fi

  printf '\nStackSet operation submitted. Monitor with:\n'
  printf '  aws cloudformation list-stack-set-operations --stack-set-name %s --region %s\n' \
    "$REGIONAL_STACKSET_NAME" "$REGION"
fi
