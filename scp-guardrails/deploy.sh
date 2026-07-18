#!/usr/bin/env bash
# Deploy SCP guardrails as two stacks from the Organizations management account.
# Stack 1: org-root baseline (region lock, service allowlist, baseline security, cost commitments)
# Stack 2: OU-level policies (EC2 size, networking, compute, storage/db cost guards)
# With no target options, every policy is deployed detached.

set -euo pipefail

ORG_BASELINE_STACK="${ORG_BASELINE_STACK:-home-scp-org-baseline}"
OU_POLICIES_STACK="${OU_POLICIES_STACK:-home-scp-ou-policies}"
REGION="${REGION:-us-east-1}"
POLICY_NAME_PREFIX="${POLICY_NAME_PREFIX:-home-guardrail}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORG_BASELINE_TEMPLATE="$SCRIPT_DIR/cloudformation/scp-org-baseline.yaml"
OU_POLICIES_TEMPLATE="$SCRIPT_DIR/cloudformation/scp-ou-policies.yaml"

ORG_ROOT_ID="NONE"
ALLOWED_REGIONS="us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1"
EC2_INSTANCE_SIZE_TARGETS="NONE"
NETWORKING_TARGETS="NONE"
COMPUTE_TARGETS="NONE"
STORAGE_DB_TARGETS="NONE"

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options]

No target options creates or updates both stacks with all policies detached.

Org-root stack options:
  --org-root-id ID                Organization root ID (r-XXXX) for baseline policies
  --allowed-regions CSV           Allowed regions (default: us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1)

OU-level stack options:
  --ec2-size-targets CSV          OU IDs for EC2 instance-size control
  --networking-targets CSV        OU IDs for networking cost guard
  --compute-targets CSV           OU IDs for compute cost guard
  --storage-db-targets CSV        OU IDs for storage and database cost guard

General:
  -h, --help                      Show this help

Examples:
  ./deploy.sh
  ./deploy.sh --org-root-id r-a1b2
  ./deploy.sh --org-root-id r-a1b2 \
    --ec2-size-targets ou-abcd-11111111,ou-abcd-22222222 \
    --networking-targets ou-abcd-11111111,ou-abcd-22222222 \
    --compute-targets ou-abcd-11111111,ou-abcd-22222222 \
    --storage-db-targets ou-abcd-11111111,ou-abcd-22222222

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
    --org-root-id)
      require_value "$@"; ORG_ROOT_ID="$2"; shift 2 ;;
    --allowed-regions)
      require_value "$@"; ALLOWED_REGIONS="$2"; shift 2 ;;
    --ec2-size-targets)
      require_value "$@"; EC2_INSTANCE_SIZE_TARGETS="$2"; shift 2 ;;
    --networking-targets)
      require_value "$@"; NETWORKING_TARGETS="$2"; shift 2 ;;
    --compute-targets)
      require_value "$@"; COMPUTE_TARGETS="$2"; shift 2 ;;
    --storage-db-targets)
      require_value "$@"; STORAGE_DB_TARGETS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown option '$1'." >&2
      usage >&2
      exit 2 ;;
  esac
done

validate_org_root_id() {
  local id="$1"
  [[ "$id" == "NONE" ]] && return 0
  if [[ ! "$id" =~ ^r-[a-z0-9]{4,32}$ ]]; then
    echo "Error: invalid org root ID '$id'; expected format r-XXXX (e.g., r-a1b2)." >&2
    exit 2
  fi
}

validate_ou_targets() {
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

validate_org_root_id "$ORG_ROOT_ID"
validate_ou_targets "EC2 size" "$EC2_INSTANCE_SIZE_TARGETS"
validate_ou_targets "networking" "$NETWORKING_TARGETS"
validate_ou_targets "compute" "$COMPUTE_TARGETS"
validate_ou_targets "storage-db" "$STORAGE_DB_TARGETS"
validate_regions "allowed" "$ALLOWED_REGIONS"

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
printf '\n  Org-root baseline stack (%s):\n' "$ORG_BASELINE_STACK"
printf '    Org root target:   %s (regions: %s)\n' "$ORG_ROOT_ID" "$ALLOWED_REGIONS"
printf '\n  OU policies stack (%s):\n' "$OU_POLICIES_STACK"
printf '    EC2 size control:        %s\n' "$EC2_INSTANCE_SIZE_TARGETS"
printf '    Networking cost guard:   %s\n' "$NETWORKING_TARGETS"
printf '    Compute cost guard:      %s\n' "$COMPUTE_TARGETS"
printf '    Storage/DB cost guard:   %s\n' "$STORAGE_DB_TARGETS"

HAS_ATTACHMENTS=false
for targets in "$ORG_ROOT_ID" "$EC2_INSTANCE_SIZE_TARGETS" \
  "$NETWORKING_TARGETS" "$COMPUTE_TARGETS" "$STORAGE_DB_TARGETS"; do
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

echo ""
echo "Deploying org-root baseline stack '$ORG_BASELINE_STACK' in '$REGION'..."
aws cloudformation deploy \
  --stack-name "$ORG_BASELINE_STACK" \
  --template-file "$ORG_BASELINE_TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PolicyNamePrefix=$POLICY_NAME_PREFIX" \
    "AllowedRegions=$ALLOWED_REGIONS" \
    "OrgRootTargetId=$ORG_ROOT_ID"

echo "Org-root baseline stack deployed. Policy IDs:"
aws cloudformation describe-stacks \
  --stack-name "$ORG_BASELINE_STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Policy:OutputKey,Id:OutputValue}' \
  --output table

echo ""
echo "Deploying OU policies stack '$OU_POLICIES_STACK' in '$REGION'..."
aws cloudformation deploy \
  --stack-name "$OU_POLICIES_STACK" \
  --template-file "$OU_POLICIES_TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PolicyNamePrefix=$POLICY_NAME_PREFIX" \
    "Ec2InstanceSizeTargetIds=$EC2_INSTANCE_SIZE_TARGETS" \
    "NetworkingCostGuardTargetIds=$NETWORKING_TARGETS" \
    "ComputeCostGuardTargetIds=$COMPUTE_TARGETS" \
    "StorageDbCostGuardTargetIds=$STORAGE_DB_TARGETS"

echo "OU policies stack deployed. Policy IDs:"
aws cloudformation describe-stacks \
  --stack-name "$OU_POLICIES_STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Policy:OutputKey,Id:OutputValue}' \
  --output table

echo ""
echo "Both stacks deployed successfully."
