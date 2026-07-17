#!/usr/bin/env bash
# Verify permanent profiles and account assignments, then remove the temporary
# bootstrap assignment and permission set through IdentityCenterAdmin.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 6 && $# -le 7 ]] || fail "Usage: $0 <instance-arn> <management-account-id> <test-account-id> <management-user-id> <workload-user-id> <temporary-permission-set-arn> [prod-account-id]"
command -v aws >/dev/null 2>&1 || fail "AWS CLI v2 is required"

INSTANCE_ARN="$1"
MANAGEMENT_ACCOUNT_ID="$2"
TEST_ACCOUNT_ID="$3"
MANAGEMENT_PRINCIPAL_ID="$4"
WORKLOAD_PRINCIPAL_ID="$5"
TEMP_PERMISSION_SET_ARN="$6"
PROD_ACCOUNT_ID="${7:-}"
REGION="${REGION:-}"
MANAGEMENT_READ_ONLY_PROFILE="${MANAGEMENT_READ_ONLY_PROFILE:-}"
LANDING_ZONE_PROFILE="${LANDING_ZONE_PROFILE:-}"
IDENTITY_CENTER_PROFILE="${IDENTITY_CENTER_PROFILE:-}"
WORKLOAD_BILLING_PROFILE="${WORKLOAD_BILLING_PROFILE:-}"
WORKLOAD_TEST_PROFILE="${WORKLOAD_TEST_PROFILE:-}"
WORKLOAD_PROD_PROFILE="${WORKLOAD_PROD_PROFILE:-}"

[[ -n "$REGION" ]] || fail "Set REGION to the Identity Center home Region"
[[ -n "$MANAGEMENT_READ_ONLY_PROFILE" ]] || fail "Set MANAGEMENT_READ_ONLY_PROFILE"
[[ -n "$LANDING_ZONE_PROFILE" ]] || fail "Set LANDING_ZONE_PROFILE"
[[ -n "$IDENTITY_CENTER_PROFILE" ]] || fail "Set IDENTITY_CENTER_PROFILE"
[[ -n "$WORKLOAD_BILLING_PROFILE" ]] || fail "Set WORKLOAD_BILLING_PROFILE"
[[ -n "$WORKLOAD_TEST_PROFILE" ]] || fail "Set WORKLOAD_TEST_PROFILE"
[[ -z "$PROD_ACCOUNT_ID" || -n "$WORKLOAD_PROD_PROFILE" ]] || fail "Set WORKLOAD_PROD_PROFILE when a Prod account is supplied"
[[ "$MANAGEMENT_ACCOUNT_ID" =~ ^[0-9]{12}$ && "$TEST_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "Management and Test account IDs must be 12 digits"
[[ -z "$PROD_ACCOUNT_ID" || "$PROD_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "Prod account ID must be empty or 12 digits"
[[ "$MANAGEMENT_PRINCIPAL_ID" != "$WORKLOAD_PRINCIPAL_ID" ]] || fail "Management and workload users must be different principals"

aws_profile() {
  local profile="$1"
  shift
  aws --profile "$profile" --region "$REGION" "$@"
}

verify_profile() {
  local profile="$1" expected_account="$2" expected_role="$3"
  local account arn
  account="$(aws_profile "$profile" sts get-caller-identity --query Account --output text)"
  arn="$(aws_profile "$profile" sts get-caller-identity --query Arn --output text)"
  [[ "$account" == "$expected_account" ]] || fail "Profile $profile resolves to account $account, expected $expected_account"
  [[ "$arn" == arn:aws:sts::*:assumed-role/AWSReservedSSO_${expected_role}_*/* ]] || fail "Profile $profile is not the expected $expected_role SSO role: $arn"
  printf 'Verified profile %s -> %s in %s\n' "$profile" "$expected_role" "$expected_account"
}

verify_profile "$MANAGEMENT_READ_ONLY_PROFILE" "$MANAGEMENT_ACCOUNT_ID" ManagementReadOnly
verify_profile "$LANDING_ZONE_PROFILE" "$MANAGEMENT_ACCOUNT_ID" LandingZoneAdmin
verify_profile "$IDENTITY_CENTER_PROFILE" "$MANAGEMENT_ACCOUNT_ID" IdentityCenterAdmin
verify_profile "$WORKLOAD_BILLING_PROFILE" "$MANAGEMENT_ACCOUNT_ID" BillingReadOnly
verify_profile "$WORKLOAD_TEST_PROFILE" "$TEST_ACCOUNT_ID" WorkloadAdmin
if [[ -n "$PROD_ACCOUNT_ID" ]]; then
  verify_profile "$WORKLOAD_PROD_PROFILE" "$PROD_ACCOUNT_ID" WorkloadAdmin
fi

aws_idc() {
  aws_profile "$IDENTITY_CENTER_PROFILE" "$@"
}

ORG_MANAGEMENT_ID="$(aws_idc organizations describe-organization \
  --query 'Organization.ManagementAccountId || Organization.MasterAccountId' \
  --output text)"
[[ "$ORG_MANAGEMENT_ID" == "$MANAGEMENT_ACCOUNT_ID" ]] || fail "IdentityCenterAdmin is not operating in the supplied management organization"

find_permission_set() {
  local wanted="$1" arn name
  while read -r arn; do
    [[ -n "$arn" ]] || continue
    name="$(aws_idc sso-admin describe-permission-set \
      --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" \
      --query 'PermissionSet.Name' --output text)"
    if [[ "$name" == "$wanted" ]]; then
      printf '%s\n' "$arn"
      return 0
    fi
  done < <(aws_idc sso-admin list-permission-sets \
    --instance-arn "$INSTANCE_ARN" \
    --query 'PermissionSets[]' --output text | tr '\t' '\n')
  return 1
}

assignment_exists() {
  local account_id="$1" permission_set_arn="$2" principal_id="$3"
  aws_idc sso-admin list-account-assignments \
    --instance-arn "$INSTANCE_ARN" \
    --account-id "$account_id" \
    --permission-set-arn "$permission_set_arn" \
    --query 'AccountAssignments[?PrincipalType==`USER`].PrincipalId' \
    --output text | tr '\t' '\n' | grep -Fqx "$principal_id"
}

verify_assignment() {
  local role_name="$1" account_id="$2" principal_id="$3" arn
  arn="$(find_permission_set "$role_name")" || fail "Permanent permission set $role_name was not found"
  assignment_exists "$account_id" "$arn" "$principal_id" || fail "$role_name is not assigned to the expected user/account"
  printf 'Verified assignment %s in account %s\n' "$role_name" "$account_id"
}

verify_assignment ManagementReadOnly "$MANAGEMENT_ACCOUNT_ID" "$MANAGEMENT_PRINCIPAL_ID"
verify_assignment LandingZoneAdmin "$MANAGEMENT_ACCOUNT_ID" "$MANAGEMENT_PRINCIPAL_ID"
verify_assignment IdentityCenterAdmin "$MANAGEMENT_ACCOUNT_ID" "$MANAGEMENT_PRINCIPAL_ID"
verify_assignment BillingReadOnly "$MANAGEMENT_ACCOUNT_ID" "$WORKLOAD_PRINCIPAL_ID"
verify_assignment WorkloadAdmin "$TEST_ACCOUNT_ID" "$WORKLOAD_PRINCIPAL_ID"
if [[ -n "$PROD_ACCOUNT_ID" ]]; then
  verify_assignment WorkloadAdmin "$PROD_ACCOUNT_ID" "$WORKLOAD_PRINCIPAL_ID"
fi

BILLING_READ_ONLY_ARN="$(find_permission_set BillingReadOnly)" || fail "Permanent permission set BillingReadOnly was not found"
WORKLOAD_MANAGEMENT_ASSIGNMENTS="$(aws_idc sso-admin list-account-assignments-for-principal \
  --instance-arn "$INSTANCE_ARN" \
  --principal-id "$WORKLOAD_PRINCIPAL_ID" \
  --principal-type USER \
  --query "AccountAssignments[?AccountId=='$MANAGEMENT_ACCOUNT_ID'].[PermissionSetArn,PrincipalType,PrincipalId]" \
  --output text)"
EXPECTED_BILLING_ASSIGNMENT="${BILLING_READ_ONLY_ARN}"$'\t'"USER"$'\t'"${WORKLOAD_PRINCIPAL_ID}"
[[ "$WORKLOAD_MANAGEMENT_ASSIGNMENTS" == "$EXPECTED_BILLING_ASSIGNMENT" ]] ||
  fail "Workload user still has an unexpected direct or group-derived management-account assignment; remove legacy Billing access before retiring bootstrap"
printf 'Verified BillingReadOnly is the workload user\047s only management-account assignment.\n'

TEMP_NAME="$(aws_idc sso-admin describe-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$TEMP_PERMISSION_SET_ARN" \
  --query 'PermissionSet.Name' --output text)"
[[ "$TEMP_NAME" == "TemporaryBootstrapAdministrator" ]] || fail "Refusing to delete permission set named $TEMP_NAME"

TEMP_PROVISIONED_ACCOUNTS="$(aws_idc sso-admin list-accounts-for-provisioned-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$TEMP_PERMISSION_SET_ARN" \
  --provisioning-status LATEST_PERMISSION_SET_PROVISIONED \
  --query 'AccountIds[]' --output text | tr '\t' '\n' | sed '/^$/d')"
TEMP_PROVISIONED_COUNT="$(printf '%s\n' "$TEMP_PROVISIONED_ACCOUNTS" | grep -c . || true)"
[[ "$TEMP_PROVISIONED_COUNT" == "1" ]] || fail "Temporary permission set is provisioned to $TEMP_PROVISIONED_COUNT accounts; expected only management"
[[ "$TEMP_PROVISIONED_ACCOUNTS" == "$MANAGEMENT_ACCOUNT_ID" ]] || fail "Temporary permission set is provisioned outside the expected management account: $TEMP_PROVISIONED_ACCOUNTS"

TEMP_COUNT="$(aws_idc sso-admin list-account-assignments \
  --instance-arn "$INSTANCE_ARN" \
  --account-id "$MANAGEMENT_ACCOUNT_ID" \
  --permission-set-arn "$TEMP_PERMISSION_SET_ARN" \
  --query 'length(AccountAssignments)' --output text)"
[[ "$TEMP_COUNT" == "1" ]] || fail "Temporary permission set has $TEMP_COUNT management-account assignments; expected exactly one"
assignment_exists "$MANAGEMENT_ACCOUNT_ID" "$TEMP_PERMISSION_SET_ARN" "$MANAGEMENT_PRINCIPAL_ID" || fail "Temporary assignment does not belong to the expected management user"

printf 'All permanent profiles and assignments verified. Removing temporary assignment...\n'
REQUEST_ID="$(aws_idc sso-admin delete-account-assignment \
  --instance-arn "$INSTANCE_ARN" \
  --target-id "$MANAGEMENT_ACCOUNT_ID" \
  --target-type AWS_ACCOUNT \
  --permission-set-arn "$TEMP_PERMISSION_SET_ARN" \
  --principal-type USER \
  --principal-id "$MANAGEMENT_PRINCIPAL_ID" \
  --query 'AccountAssignmentDeletionStatus.RequestId' \
  --output text)"

while :; do
  STATUS="$(aws_idc sso-admin describe-account-assignment-deletion-status \
    --instance-arn "$INSTANCE_ARN" \
    --account-assignment-deletion-request-id "$REQUEST_ID" \
    --query 'AccountAssignmentDeletionStatus.Status' \
    --output text)"
  case "$STATUS" in
    SUCCEEDED) break ;;
    FAILED)
      REASON="$(aws_idc sso-admin describe-account-assignment-deletion-status \
        --instance-arn "$INSTANCE_ARN" \
        --account-assignment-deletion-request-id "$REQUEST_ID" \
        --query 'AccountAssignmentDeletionStatus.FailureReason' \
        --output text)"
      fail "Temporary assignment deletion failed: $REASON"
      ;;
    IN_PROGRESS) sleep 3 ;;
    *) fail "Unexpected deletion status: $STATUS" ;;
  esac
done

aws_idc sso-admin delete-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$TEMP_PERMISSION_SET_ARN"

printf 'Temporary assignment and permission set removed after permanent access verification.\n'
