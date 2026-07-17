#!/usr/bin/env bash
# Deploy permanent IAM Identity Center access through an SSO profile only.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 5 && $# -le 6 ]] || fail "Usage: $0 <instance-arn> <management-account-id> <test-account-id> <management-user-id> <workload-user-id> [prod-account-id]"
command -v aws >/dev/null 2>&1 || fail "AWS CLI v2 is required"

INSTANCE_ARN="$1"
MANAGEMENT_ACCOUNT_ID="$2"
TEST_ACCOUNT_ID="$3"
MANAGEMENT_PRINCIPAL_ID="$4"
WORKLOAD_PRINCIPAL_ID="$5"
PROD_ACCOUNT_ID="${6:-}"
REGION="${REGION:-}"
SSO_PROFILE="${SSO_PROFILE:-${AWS_PROFILE:-}}"
STACK_NAME="${STACK_NAME:-home-idc-permission-sets}"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/cloudformation/idc-permission-sets.yaml"

[[ -n "$REGION" ]] || fail "Set REGION to the Identity Center home Region"
[[ -n "$SSO_PROFILE" ]] || fail "Set SSO_PROFILE (or AWS_PROFILE) to the temporary bootstrap or IdentityCenterAdmin SSO profile"
[[ "$INSTANCE_ARN" =~ ^arn:aws:sso:::instance/ssoins-[0-9A-Za-z-]+$ ]] || fail "Invalid Identity Center instance ARN"
for value in "$MANAGEMENT_ACCOUNT_ID" "$TEST_ACCOUNT_ID"; do
  [[ "$value" =~ ^[0-9]{12}$ ]] || fail "Account IDs must be 12 digits"
done
[[ -z "$PROD_ACCOUNT_ID" || "$PROD_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "Prod account ID must be empty or 12 digits"
[[ -n "$MANAGEMENT_PRINCIPAL_ID" && -n "$WORKLOAD_PRINCIPAL_ID" ]] || fail "Both user IDs are required"
[[ "$MANAGEMENT_PRINCIPAL_ID" != "$WORKLOAD_PRINCIPAL_ID" ]] || fail "Management and workload users must be different principals"
[[ "$MANAGEMENT_ACCOUNT_ID" != "$TEST_ACCOUNT_ID" ]] || fail "Management and Test must be different accounts"
[[ -z "$PROD_ACCOUNT_ID" || "$PROD_ACCOUNT_ID" != "$MANAGEMENT_ACCOUNT_ID" ]] || fail "Prod cannot be the management account"
[[ -z "$PROD_ACCOUNT_ID" || "$PROD_ACCOUNT_ID" != "$TEST_ACCOUNT_ID" ]] || fail "Prod and Test must be different accounts"

aws_sso() {
  aws --profile "$SSO_PROFILE" --region "$REGION" "$@"
}

CALLER_ACCOUNT="$(aws_sso sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws_sso sts get-caller-identity --query Arn --output text)"
[[ "$CALLER_ACCOUNT" == "$MANAGEMENT_ACCOUNT_ID" ]] || fail "SSO caller is in account $CALLER_ACCOUNT, not management account $MANAGEMENT_ACCOUNT_ID"
case "$CALLER_ARN" in
  arn:aws:sts::*:assumed-role/AWSReservedSSO_TemporaryBootstrapAdministrator_*/*|\
  arn:aws:sts::*:assumed-role/AWSReservedSSO_IdentityCenterAdmin_*/*) ;;
  *) fail "Caller is not the temporary bootstrap or IdentityCenterAdmin SSO role: $CALLER_ARN" ;;
esac

ORG_MANAGEMENT_ID="$(aws_sso organizations describe-organization \
  --query 'Organization.ManagementAccountId || Organization.MasterAccountId' \
  --output text)"
[[ "$ORG_MANAGEMENT_ID" == "$MANAGEMENT_ACCOUNT_ID" ]] || fail "Organizations reports management account $ORG_MANAGEMENT_ID, not $MANAGEMENT_ACCOUNT_ID"

account_status() {
  aws_sso organizations list-accounts \
    --query "Accounts[?Id=='$1'].Status | [0]" \
    --output text
}
[[ "$(account_status "$TEST_ACCOUNT_ID")" == "ACTIVE" ]] || fail "Test account is not an active organization account"
if [[ -n "$PROD_ACCOUNT_ID" ]]; then
  [[ "$(account_status "$PROD_ACCOUNT_ID")" == "ACTIVE" ]] || fail "Prod account is not an active organization account"
fi

IDENTITY_STORE_ID="$(aws_sso sso-admin list-instances \
  --query "Instances[?InstanceArn=='$INSTANCE_ARN'].IdentityStoreId | [0]" \
  --output text)"
[[ -n "$IDENTITY_STORE_ID" && "$IDENTITY_STORE_ID" != "None" ]] || fail "Identity Center instance was not found in $REGION"
aws_sso identitystore describe-user --identity-store-id "$IDENTITY_STORE_ID" --user-id "$MANAGEMENT_PRINCIPAL_ID" >/dev/null || fail "Management user does not exist in the instance Identity Store"
aws_sso identitystore describe-user --identity-store-id "$IDENTITY_STORE_ID" --user-id "$WORKLOAD_PRINCIPAL_ID" >/dev/null || fail "Workload user does not exist in the instance Identity Store"

printf 'Preflight passed: management account, organization, instance, accounts, and distinct users verified.\n'
printf 'Deploying stack %s through SSO profile %s...\n' "$STACK_NAME" "$SSO_PROFILE"
aws_sso cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "IdentityCenterInstanceArn=$INSTANCE_ARN" \
    "ManagementAccountId=$MANAGEMENT_ACCOUNT_ID" \
    "TestAccountId=$TEST_ACCOUNT_ID" \
    "ProdAccountId=$PROD_ACCOUNT_ID" \
    "ManagementPrincipalId=$MANAGEMENT_PRINCIPAL_ID" \
    "WorkloadPrincipalId=$WORKLOAD_PRINCIPAL_ID" \
    "ManagementReadOnlySessionDuration=${MANAGEMENT_READ_ONLY_SESSION_DURATION:-PT4H}" \
    "LandingZoneAdminSessionDuration=${LANDING_ZONE_ADMIN_SESSION_DURATION:-PT2H}" \
    "IdentityCenterAdminSessionDuration=${IDENTITY_CENTER_ADMIN_SESSION_DURATION:-PT1H}" \
    "BillingReadOnlySessionDuration=${BILLING_READ_ONLY_SESSION_DURATION:-PT4H}" \
    "WorkloadAdminSessionDuration=${WORKLOAD_ADMIN_SESSION_DURATION:-PT4H}"

aws_sso cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
  --output table

printf '\nConfigure and test every permanent SSO profile before running retire-bootstrap.sh.\n'
