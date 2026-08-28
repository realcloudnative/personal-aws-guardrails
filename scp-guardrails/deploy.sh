#!/usr/bin/env bash
# Deploy SCP guardrails as two stacks from the Organizations management account.
# Stack 1: org-root baseline (security, regions, service allowlist, cost commitments)
# Stack 2: OU-level opinionated cost guard (one policy, all environment-specific boundaries)
# With no target options, every policy is deployed detached.

set -euo pipefail

ORG_BASELINE_STACK="${ORG_BASELINE_STACK:-paws-scp-org-baseline}"
OU_POLICIES_STACK="${OU_POLICIES_STACK:-paws-scp-ou-policies}"
REGION="${REGION:-us-east-1}"
POLICY_NAME_PREFIX="${POLICY_NAME_PREFIX:-paws}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORG_BASELINE_TEMPLATE="$SCRIPT_DIR/cloudformation/scp-org-baseline.yaml"
OU_POLICIES_TEMPLATE="$SCRIPT_DIR/cloudformation/scp-ou-policies.yaml"

# Empty means "retain the deployed stack's current value" (NONE on first deploy).
# Detaching always requires an explicit NONE plus the DETACH confirmation below.
ORG_ROOT_ID=""
ALLOWED_REGIONS="us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1"
OPINIONATED_COST_TARGETS=""

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [options]

Omitted target options RETAIN the deployed stack's current attachments
(NONE on a first deploy). Detaching therefore never happens by omission:
pass NONE explicitly, and confirm it.

Org-root stack options:
  --org-root-id ID|NONE           Organization root ID (r-XXXX) for baseline policies,
                                  or NONE to detach (requires DETACH confirmation)
  --allowed-regions CSV           Allowed regions (default: us-east-1,us-west-2,eu-central-1,eu-north-1,ap-southeast-1)

OU-level stack options:
  --opinionated-targets CSV|NONE  OU IDs for the opinionated cost guard,
                                  or NONE to detach (requires DETACH confirmation)

General:
  -h, --help                      Show this help

Examples:
  ./deploy.sh                     # template changes only; attachments retained
  ./deploy.sh --org-root-id r-a1b2
  ./deploy.sh --opinionated-targets ou-abcd-11111111,ou-abcd-22222222
  ./deploy.sh --opinionated-targets NONE   # deliberate detach

A NEW attachment requires typing ATTACH at the prompt; a DETACH requires
typing DETACH. For intentional non-interactive use, set
ATTACH_CONFIRMATION=ATTACH and/or DETACH_CONFIRMATION=DETACH. Retained
(unchanged) attachments need no confirmation.
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
    --opinionated-targets)
      require_value "$@"; OPINIONATED_COST_TARGETS="$2"; shift 2 ;;
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
  [[ -z "$id" || "$id" == "NONE" ]] && return 0
  if [[ ! "$id" =~ ^r-[a-z0-9]{4,32}$ ]]; then
    echo "Error: invalid org root ID '$id'; expected format r-XXXX (e.g., r-a1b2)." >&2
    exit 2
  fi
}

validate_ou_targets() {
  local label="$1" csv="$2" target
  [[ -z "$csv" || "$csv" == "NONE" ]] && return 0
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
validate_ou_targets "opinionated cost guard" "$OPINIONATED_COST_TARGETS"
validate_regions "allowed" "$ALLOWED_REGIONS"

read -r CALLER_ACCOUNT CALLER_ARN CALLER_USER_ID < <(
  aws sts get-caller-identity --query '[Account,Arn,UserId]' --output text
)
printf 'AWS identity:\n  Account: %s\n  ARN:     %s\n  UserId:  %s\n' \
  "$CALLER_ACCOUNT" "$CALLER_ARN" "$CALLER_USER_ID"
if [[ "$CALLER_ARN" != arn:aws:sts::*:assumed-role/AWSReservedSSO_LandingZoneAdmin_*/* \
      && "$CALLER_ARN" != arn:aws:iam::*:user/* ]]; then
  echo "Error: SCP deployment requires the LandingZoneAdmin SSO role or a management-account IAM user, not $CALLER_ARN." >&2
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

# Read a deployed stack's current parameter value; empty if the stack does
# not exist yet. Guards against accidental detachment: omitted CLI options
# fall back to these values, never to NONE.
current_param() {
  local stack="$1" key="$2" value
  value="$(aws cloudformation describe-stacks \
    --stack-name "$stack" --region "$REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='$key'].ParameterValue | [0]" \
    --output text 2>/dev/null)" || return 0
  [[ "$value" == "None" ]] && value=""
  printf '%s' "$value"
}

CURRENT_ORG_ROOT="$(current_param "$ORG_BASELINE_STACK" OrgRootTargetId)"
CURRENT_OPINIONATED="$(current_param "$OU_POLICIES_STACK" OpinionatedCostGuardTargetIds)"

ORG_ROOT_RETAINED=false
OPINIONATED_RETAINED=false
if [[ -z "$ORG_ROOT_ID" ]]; then
  ORG_ROOT_ID="${CURRENT_ORG_ROOT:-NONE}"
  ORG_ROOT_RETAINED=true
fi
if [[ -z "$OPINIONATED_COST_TARGETS" ]]; then
  OPINIONATED_COST_TARGETS="${CURRENT_OPINIONATED:-NONE}"
  OPINIONATED_RETAINED=true
fi

describe_plan() {
  local new="$1" retained="$2"
  if [[ "$retained" == true ]]; then printf '%s (retained)' "$new"; else printf '%s' "$new"; fi
}
printf '\nAttachment plan (NONE means detached):\n'
printf '  Org-root baseline:       %s (regions: %s)\n' "$(describe_plan "$ORG_ROOT_ID" "$ORG_ROOT_RETAINED")" "$ALLOWED_REGIONS"
printf '  Opinionated cost guard:  %s\n' "$(describe_plan "$OPINIONATED_COST_TARGETS" "$OPINIONATED_RETAINED")"

# A change of attachment needs confirming; retained (unchanged) values do not.
# New/changed targets require ATTACH; removing existing targets requires DETACH.
NEEDS_ATTACH=false
NEEDS_DETACH=false
check_transition() {
  local current="$1" new="$2" label="$3"
  [[ "$new" == "${current:-NONE}" ]] && return 0
  if [[ "$new" == "NONE" ]]; then
    echo "WARNING: this deployment DETACHES the $label SCP (currently: ${current:-NONE})."
    NEEDS_DETACH=true
  else
    NEEDS_ATTACH=true
  fi
}
check_transition "$CURRENT_ORG_ROOT" "$ORG_ROOT_ID" "org-root baseline"
check_transition "$CURRENT_OPINIONATED" "$OPINIONATED_COST_TARGETS" "opinionated cost guard"

require_confirmation() {
  local word="$1" provided="$2" prompt="$3" confirmation
  confirmation="$provided"
  if [[ "$confirmation" != "$word" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: this change requires interactive confirmation or ${word}_CONFIRMATION=${word}." >&2
      exit 1
    fi
    read -r -p "$prompt" confirmation
  fi
  if [[ "$confirmation" != "$word" ]]; then
    echo "${word} not confirmed; nothing was deployed." >&2
    exit 1
  fi
}
if [[ "$NEEDS_DETACH" == true ]]; then
  require_confirmation DETACH "${DETACH_CONFIRMATION:-}" "Type DETACH to authorize removing these SCP attachments: "
fi
if [[ "$NEEDS_ATTACH" == true ]]; then
  require_confirmation ATTACH "${ATTACH_CONFIRMATION:-}" "Type ATTACH to authorize these SCP attachments: "
fi
if [[ "$NEEDS_ATTACH" == false && "$NEEDS_DETACH" == false ]]; then
  echo "Attachments unchanged; deploying template/content changes only."
fi

echo ""
echo "Deploying org-root baseline stack '$ORG_BASELINE_STACK'..."
aws cloudformation deploy \
  --stack-name "$ORG_BASELINE_STACK" \
  --template-file "$ORG_BASELINE_TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PolicyNamePrefix=$POLICY_NAME_PREFIX" \
    "OrgRootTargetId=$ORG_ROOT_ID"

echo "Org-root baseline deployed."

echo ""
echo "Deploying OU policies stack '$OU_POLICIES_STACK'..."
aws cloudformation deploy \
  --stack-name "$OU_POLICIES_STACK" \
  --template-file "$OU_POLICIES_TEMPLATE" \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "PolicyNamePrefix=$POLICY_NAME_PREFIX" \
    "OpinionatedCostGuardTargetIds=$OPINIONATED_COST_TARGETS"

echo "OU policies deployed."
echo ""
echo "Policy IDs:"
aws cloudformation describe-stacks \
  --stack-name "$ORG_BASELINE_STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Policy:OutputKey,Id:OutputValue}' \
  --output table
aws cloudformation describe-stacks \
  --stack-name "$OU_POLICIES_STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[].{Policy:OutputKey,Id:OutputValue}' \
  --output table
