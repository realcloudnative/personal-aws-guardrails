#!/usr/bin/env bash
# Deploy non-SCP organization policies: declarative EC2, declarative S3,
# AI opt-out, and resource control policy (data perimeter).
#
# Prerequisites:
#   - Each policy type must be enabled on the org root before first deploy.
#   - Run with management account credentials.
#
# Usage:
#   ./deploy.sh --org-root-id r-XXXX --org-id o-XXXXXXXXXX

set -euo pipefail

STACK_NAME="${STACK_NAME:-paws-org-policies}"
REGION="${REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cloudformation/org-policies.yaml"

ORG_ROOT_ID=""
ORG_ID=""

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh --org-root-id r-XXXX --org-id o-XXXXXXXXXX

Required:
  --org-root-id ID    Organization root ID (r-XXXX)
  --org-id ID         Organization ID (o-XXXXXXXXXX)

Environment:
  AWS_PROFILE         AWS CLI profile (default: paws-mgmt-landing)
  REGION              Deployment region (default: us-east-1)
  STACK_NAME          Override stack name (default: paws-org-policies)

Before first deployment, enable all required policy types:
  aws organizations enable-policy-type --root-id r-XXXX --policy-type DECLARATIVE_POLICY_EC2
  aws organizations enable-policy-type --root-id r-XXXX --policy-type S3_POLICY
  aws organizations enable-policy-type --root-id r-XXXX --policy-type AISERVICES_OPT_OUT_POLICY
  aws organizations enable-policy-type --root-id r-XXXX --policy-type RESOURCE_CONTROL_POLICY
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-root-id) ORG_ROOT_ID="$2"; shift 2 ;;
    --org-id)      ORG_ID="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$ORG_ROOT_ID" ]] && { echo "ERROR: --org-root-id is required"; usage; }
[[ -z "$ORG_ID" ]] && { echo "ERROR: --org-id is required"; usage; }

AWS_PROFILE="${AWS_PROFILE:-paws-mgmt-landing}"

printf 'Enabling policy types (idempotent)...\n'
for ptype in DECLARATIVE_POLICY_EC2 S3_POLICY AISERVICES_OPT_OUT_POLICY RESOURCE_CONTROL_POLICY; do
  aws --profile "$AWS_PROFILE" --region "$REGION" organizations enable-policy-type \
    --root-id "$ORG_ROOT_ID" --policy-type "$ptype" 2>/dev/null || true
done

printf 'Deploying %s...\n' "$STACK_NAME"
aws --profile "$AWS_PROFILE" --region "$REGION" cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    OrgRootId="$ORG_ROOT_ID" \
    OrgId="$ORG_ID"

printf '\nDeployed. Policy IDs:\n'
aws --profile "$AWS_PROFILE" --region "$REGION" cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
