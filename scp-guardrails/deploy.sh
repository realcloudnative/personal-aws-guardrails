#!/usr/bin/env bash
# Deploy independently targeted SCP guardrails from the Organizations management account.
# With no target options, every policy is deployed detached.

set -euo pipefail

STACK_NAME="${STACK_NAME:-home-scp-guardrails}"
REGION="${REGION:-us-east-1}"
POLICY_NAME_PREFIX="${POLICY_NAME_PREFIX:-home-guardrail}"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/cloudformation/scp-guardrails.yaml"

PROD_REGION_TARGETS="NONE"
TEST_REGION_TARGETS="NONE"
SERVICE_ALLOWLIST_TARGETS="NONE"
EC2_INSTANCE_SIZE_TARGETS="NONE"
BASELINE_SECURITY_TARGETS="NONE"
COST_CONTROL_TARGETS="NONE"
PROD_REGIONS="us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1"
TEST_REGIONS="us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1"

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options]

No target options creates or updates the stack with all policies detached.
Only OU IDs are accepted; attaching guardrails to the organization root is not supported.

Options:
  --prod-region-targets CSV       OU IDs for the Prod region lock
  --test-region-targets CSV       OU IDs for the Test region lock
  --service-allowlist-targets CSV OU IDs for the service allowlist
  --ec2-size-targets CSV          OU IDs for the EC2 instance-size control
  --baseline-targets CSV          OU IDs for common baseline security
  --cost-control-targets CSV      OU IDs for cost controls
  --prod-regions CSV              Prod allowed regions
  --test-regions CSV              Test allowed regions
  -h, --help                      Show this help

Examples:
  ./deploy.sh
  ./deploy.sh --prod-region-targets ou-abcd-11111111 \
    --test-region-targets ou-abcd-22222222 \
    --baseline-targets ou-abcd-11111111,ou-abcd-22222222

Any attachment requires typing ATTACH at the prompt. For intentional
non-interactive use, set ATTACH_CONFIRMATION=ATTACH.
USAGE
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "Error: $1 requires a non-empty value." >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod-region-targets)
      require_value "$@"; PROD_REGION_TARGETS="$2"; shift 2 ;;
    --test-region-targets)
      require_value "$@"; TEST_REGION_TARGETS="$2"; shift 2 ;;
    --service-allowlist-targets)
      require_value "$@"; SERVICE_ALLOWLIST_TARGETS="$2"; shift 2 ;;
    --ec2-size-targets)
      require_value "$@"; EC2_INSTANCE_SIZE_TARGETS="$2"; shift 2 ;;
    --baseline-targets)
      require_value "$@"; BASELINE_SECURITY_TARGETS="$2"; shift 2 ;;
    --cost-control-targets)
      require_value "$@"; COST_CONTROL_TARGETS="$2"; shift 2 ;;
    --prod-regions)
      require_value "$@"; PROD_REGIONS="$2"; shift 2 ;;
    --test-regions)
      require_value "$@"; TEST_REGIONS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown option '$1'." >&2
      usage >&2
      exit 2 ;;
  esac
done

validate_targets() {
  local label="$1" csv="$2" target
  [[ "$csv" == "NONE" ]] && return 0
  IFS=',' read -r -a targets <<< "$csv"
  for target in "${targets[@]}"; do
    if [[ ! "$target" =~ ^ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}$ ]]; then
      echo "Error: invalid $label target '$target'; expected an OU ID such as ou-abcd-12345678." >&2
      exit 2
    fi
  done
}

validate_regions() {
  local label="$1" csv="$2" region
  IFS=',' read -r -a regions <<< "$csv"
  if [[ ${#regions[@]} -eq 0 ]]; then
    echo "Error: $label region list cannot be empty." >&2
    exit 2
  fi
  for region in "${regions[@]}"; do
    if [[ ! "$region" =~ ^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$ ]]; then
      echo "Error: invalid region '$region' in $label region list." >&2
      exit 2
    fi
  done
}

validate_targets "Prod region-lock" "$PROD_REGION_TARGETS"
validate_targets "Test region-lock" "$TEST_REGION_TARGETS"
validate_targets "service-allowlist" "$SERVICE_ALLOWLIST_TARGETS"
validate_targets "EC2 size" "$EC2_INSTANCE_SIZE_TARGETS"
validate_targets "baseline-security" "$BASELINE_SECURITY_TARGETS"
validate_targets "cost-control" "$COST_CONTROL_TARGETS"
validate_regions "Prod" "$PROD_REGIONS"
validate_regions "Test" "$TEST_REGIONS"

read -r CALLER_ACCOUNT CALLER_ARN CALLER_USER_ID < <(
  aws sts get-caller-identity --query '[Account,Arn,UserId]' --output text
)
printf 'AWS identity:\n  Account: %s\n  ARN:     %s\n  UserId:  %s\n' \
  "$CALLER_ACCOUNT" "$CALLER_ARN" "$CALLER_USER_ID"
if [[ "$CALLER_ARN" != arn:aws:sts::*:assumed-role/AWSReservedSSO_LandingZoneAdmin_*/* ]]; then
  echo "Error: SCP deployment requires the LandingZoneAdmin SSO role, not $CALLER_ARN." >&2
  exit 1
fi

MANAGEMENT_ACCOUNT="$(
  aws organizations describe-organization \
    --query 'Organization.ManagementAccountId || Organization.MasterAccountId' --output text
)"
if [[ -z "$MANAGEMENT_ACCOUNT" || "$MANAGEMENT_ACCOUNT" == "None" ]]; then
  echo "Error: could not determine the Organizations management account." >&2
  exit 1
fi
if [[ "$CALLER_ACCOUNT" != "$MANAGEMENT_ACCOUNT" ]]; then
  echo "Error: caller account $CALLER_ACCOUNT is not the Organizations management account $MANAGEMENT_ACCOUNT." >&2
  exit 1
fi
echo "Verified Organizations management account: $MANAGEMENT_ACCOUNT"

printf '\nAttachment plan (NONE means detached):\n'
printf '  Prod region lock:  %s (regions: %s)\n' "$PROD_REGION_TARGETS" "$PROD_REGIONS"
printf '  Test region lock:  %s (regions: %s)\n' "$TEST_REGION_TARGETS" "$TEST_REGIONS"
printf '  Service allowlist: %s\n' "$SERVICE_ALLOWLIST_TARGETS"
printf '  EC2 size control:  %s\n' "$EC2_INSTANCE_SIZE_TARGETS"
printf '  Baseline security: %s\n' "$BASELINE_SECURITY_TARGETS"
printf '  Cost control:      %s\n' "$COST_CONTROL_TARGETS"

HAS_ATTACHMENTS=false
for targets in \
  "$PROD_REGION_TARGETS" "$TEST_REGION_TARGETS" "$SERVICE_ALLOWLIST_TARGETS" \
  "$EC2_INSTANCE_SIZE_TARGETS" "$BASELINE_SECURITY_TARGETS" "$COST_CONTROL_TARGETS"; do
  if [[ "$targets" != "NONE" ]]; then
    HAS_ATTACHMENTS=true
    break
  fi
done

if [[ "$HAS_ATTACHMENTS" == true ]]; then
  confirmation="${ATTACH_CONFIRMATION:-}"
  if [[ "$confirmation" != "ATTACH" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: attachments require an interactive confirmation or ATTACH_CONFIRMATION=ATTACH." >&2
      exit 1
    fi
    read -r -p "Type ATTACH to authorize these SCP attachments: " confirmation
  fi
  if [[ "$confirmation" != "ATTACH" ]]; then
    echo "Attachment not confirmed; nothing was deployed." >&2
    exit 1
  fi
else
  echo "Detached deployment: no SCP will be attached."
fi

echo "Deploying stack '$STACK_NAME' in '$REGION'..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PolicyNamePrefix=$POLICY_NAME_PREFIX" \
    "ProdAllowedRegions=$PROD_REGIONS" \
    "TestAllowedRegions=$TEST_REGIONS" \
    "ProdRegionLockTargetIds=$PROD_REGION_TARGETS" \
    "TestRegionLockTargetIds=$TEST_REGION_TARGETS" \
    "ServiceAllowlistTargetIds=$SERVICE_ALLOWLIST_TARGETS" \
    "Ec2InstanceSizeTargetIds=$EC2_INSTANCE_SIZE_TARGETS" \
    "BaselineSecurityTargetIds=$BASELINE_SECURITY_TARGETS" \
    "CostControlTargetIds=$COST_CONTROL_TARGETS"

echo "Deployment complete. Policy IDs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Policy:OutputKey,Id:OutputValue}' \
  --output table
