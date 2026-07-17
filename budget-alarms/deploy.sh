#!/usr/bin/env bash
# Deploy one managed organization-wide home Safety Net budget.
# Usage: ./deploy.sh <notification-email>
# Environment:
#   AWS_PROFILE    required LandingZoneAdmin SSO profile
#   STACK_NAME     default: home-budget-alarms
#   REGION         default: us-east-1 (Budgets control-plane endpoint)
#   OVERALL_LIMIT  default: 20 USD/month

set -euo pipefail

STACK_NAME="${STACK_NAME:-home-budget-alarms}"
REGION="${REGION:-us-east-1}"
OVERALL_LIMIT="${OVERALL_LIMIT:-20}"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/cloudformation/budget-alarms.yaml"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <notification-email>" >&2
  exit 1
fi
if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "Set AWS_PROFILE to the LandingZoneAdmin SSO profile." >&2
  exit 1
fi
if [[ ! "$OVERALL_LIMIT" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]]; then
  echo "OVERALL_LIMIT must be a number greater than or equal to 1." >&2
  exit 1
fi

EMAIL="$1"
read -r CALLER_ACCOUNT CALLER_ARN extra < <(
  aws sts get-caller-identity --region "$REGION" --query '[Account,Arn]' --output text
)
if [[ -z "${CALLER_ACCOUNT:-}" || -z "${CALLER_ARN:-}" || -n "${extra:-}" ]]; then
  echo "Refusing: could not parse caller identity." >&2
  exit 1
fi
if [[ "$CALLER_ARN" != arn:aws:sts::*:assumed-role/AWSReservedSSO_LandingZoneAdmin_*/* ]]; then
  echo "Refusing: budget deployment requires the LandingZoneAdmin SSO role, not $CALLER_ARN." >&2
  exit 1
fi
ORG_MANAGEMENT_ACCOUNT="$(aws organizations describe-organization --region "$REGION" \
  --query 'Organization.ManagementAccountId || Organization.MasterAccountId' --output text)"
if [[ "$CALLER_ACCOUNT" != "$ORG_MANAGEMENT_ACCOUNT" ]]; then
  echo "Refusing: caller account $CALLER_ACCOUNT is not Organizations management account $ORG_MANAGEMENT_ACCOUNT." >&2
  exit 1
fi

printf 'Validating template...\n'
aws cloudformation validate-template \
  --template-body "file://$TEMPLATE" \
  --region "$REGION" >/dev/null

printf "Deploying managed Safety Net stack '%s' with monthly limit USD %s...\n" \
  "$STACK_NAME" "$OVERALL_LIMIT"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "NotificationEmail=$EMAIL" \
    "OverallMonthlyLimit=$OVERALL_LIMIT"

printf '\nManaged budget outputs:\n'
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
  --output table

printf '\nThe unmanaged legacy Safety Net budget was not changed. Verify the new email subscription and alerts before separately deleting it.\n'
