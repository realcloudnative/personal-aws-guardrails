#!/usr/bin/env bash
# Optionally deploy one foundational-only GuardDuty detector in one selected Region.
# Invoking this script opts in; GuardDuty is not deployed by apply-account-baseline.sh.
# Required environment:
#   EXPECTED_ACCOUNT_ID  12-digit account ID that the active credentials must use
#   CONTROL_REGION       explicit Region for the STS identity check
#   ACCOUNT_TYPE         management or workload
# Optional environment:
#   GUARDDUTY_REGION     defaults to us-east-1 for management, eu-central-1 for workload
#   INSPECTION_REGIONS   Regions checked for conflicting enabled detectors
#   STACK_NAME           CloudFormation stack name in the selected Region

set -euo pipefail

EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
CONTROL_REGION="${CONTROL_REGION:-}"
ACCOUNT_TYPE="${ACCOUNT_TYPE:-}"
GUARDDUTY_REGION="${GUARDDUTY_REGION:-}"
INSPECTION_REGIONS="${INSPECTION_REGIONS:-us-east-1 us-west-2 eu-central-1 eu-north-1 ap-southeast-1}"
STACK_NAME="${STACK_NAME:-home-guardduty}"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/cloudformation/guardduty-detector.yaml"
ERROR_FILE="$(mktemp)"
trap 'rm -f "$ERROR_FILE"' EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_region() {
  local region="$1"
  [[ "$region" =~ ^[a-z]{2}(-[a-z0-9]+)+-[0-9]+$ ]] ||
    die "invalid AWS Region '$region'"
}

[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] ||
  die "EXPECTED_ACCOUNT_ID is required and must be exactly 12 digits"
[[ -n "$CONTROL_REGION" ]] || die "CONTROL_REGION is required"
require_region "$CONTROL_REGION"
case "$ACCOUNT_TYPE" in
  management)
    DEFAULT_GUARDDUTY_REGION="us-east-1"
    EXPECTED_ROLE="LandingZoneAdmin"
    ;;
  workload)
    DEFAULT_GUARDDUTY_REGION="eu-central-1"
    EXPECTED_ROLE="WorkloadAdmin"
    ;;
  *) die "ACCOUNT_TYPE is required and must be 'management' or 'workload'" ;;
esac
GUARDDUTY_REGION="${GUARDDUTY_REGION:-$DEFAULT_GUARDDUTY_REGION}"
require_region "$GUARDDUTY_REGION"
[[ "$STACK_NAME" =~ ^[A-Za-z][-A-Za-z0-9]{0,127}$ ]] ||
  die "STACK_NAME must be a valid CloudFormation stack name"
[[ -r "$TEMPLATE" ]] || die "template is not readable: $TEMPLATE"
command -v python3 >/dev/null 2>&1 || die "python3 is required to validate AWS JSON responses"

identity="$(aws sts get-caller-identity \
  --region "$CONTROL_REGION" \
  --query '[Account,Arn]' \
  --output text)" || die "could not inspect the caller identity"
read -r CALLER_ACCOUNT CALLER_ARN extra <<< "$identity"
[[ -n "${CALLER_ACCOUNT:-}" && -n "${CALLER_ARN:-}" && -z "${extra:-}" ]] ||
  die "could not parse the caller identity"

echo "Caller ARN: $CALLER_ARN"
echo "Caller account: $CALLER_ACCOUNT"
echo "Expected account: $EXPECTED_ACCOUNT_ID"
echo "Account type: $ACCOUNT_TYPE"
echo "Control Region: $CONTROL_REGION"
echo "GuardDuty Region: $GUARDDUTY_REGION"
[[ "$CALLER_ACCOUNT" == "$EXPECTED_ACCOUNT_ID" ]] ||
  die "active credentials are for account $CALLER_ACCOUNT, not EXPECTED_ACCOUNT_ID $EXPECTED_ACCOUNT_ID; no changes were made"
case "$CALLER_ARN" in
  arn:aws:sts::*:assumed-role/AWSReservedSSO_${EXPECTED_ROLE}_*/*) ;;
  *) die "ACCOUNT_TYPE '$ACCOUNT_TYPE' requires the $EXPECTED_ROLE SSO role, not $CALLER_ARN" ;;
esac

read -r -a REGIONS_TO_INSPECT <<< "$INSPECTION_REGIONS"
((${#REGIONS_TO_INSPECT[@]} > 0)) || die "INSPECTION_REGIONS must contain at least one Region"
SEEN_REGIONS=" "
for region in "${REGIONS_TO_INSPECT[@]}"; do
  require_region "$region"
  [[ "$SEEN_REGIONS" != *" $region "* ]] || die "duplicate Region '$region' in INSPECTION_REGIONS"
  SEEN_REGIONS+="$region "
done

# A disabled detector may remain for historical findings, but another enabled
# detector would defeat this repository's deliberate one-Region design.
echo "Inspecting non-selected Regions for enabled GuardDuty detectors..."
for region in "${REGIONS_TO_INSPECT[@]}"; do
  [[ "$region" != "$GUARDDUTY_REGION" ]] || continue
  detectors_json="$(aws guardduty list-detectors \
    --region "$region" \
    --output json)" || die "[$region] could not inspect GuardDuty detectors"
  detector_ids_text="$(python3 -c '
import json, sys
value = json.load(sys.stdin)
ids = value.get("DetectorIds")
if not isinstance(ids, list) or not all(isinstance(item, str) and item for item in ids):
    raise SystemExit("invalid DetectorIds response")
print(" ".join(ids))
' <<< "$detectors_json")" || die "[$region] could not parse GuardDuty detector inventory"
  detector_ids=()
  [[ -z "$detector_ids_text" ]] || read -r -a detector_ids <<< "$detector_ids_text"
  ((${#detector_ids[@]} <= 1)) ||
    die "[$region] GuardDuty returned multiple detectors, which this deployment cannot reconcile"
  [[ ${#detector_ids[@]} -eq 1 ]] || continue
  detector_id="${detector_ids[0]}"
  detector_status="$(aws guardduty get-detector \
    --detector-id "$detector_id" \
    --region "$region" \
    --query Status \
    --output text)" || die "[$region] could not inspect detector $detector_id"
  case "$detector_status" in
    DISABLED)
      echo "  [$region] detector $detector_id is DISABLED; retained historical state will not create new findings."
      ;;
    ENABLED)
      die "[$region] detector $detector_id is ENABLED outside selected Region $GUARDDUTY_REGION. To avoid multi-Region findings, review it and explicitly disable it (or delete its owning stack) before rerunning. This script never disables or deletes detectors."
      ;;
    *) die "[$region] detector $detector_id has unexpected status '$detector_status'" ;;
  esac
done

TARGET_REGIONS=("$GUARDDUTY_REGION")
echo "GuardDuty target Region: $GUARDDUTY_REGION"

for region in "${TARGET_REGIONS[@]}"; do
  echo
  echo "[$region] Inspecting CloudFormation ownership and GuardDuty detector state..."

  stack_exists=false
  if stack_status="$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$region" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>"$ERROR_FILE")"; then
    stack_exists=true
    [[ -n "$stack_status" && "$stack_status" != "None" ]] ||
      die "[$region] could not parse stack status for '$STACK_NAME'"
    echo "  existing stack: $STACK_NAME ($stack_status)"
  elif grep -Eq '\(ValidationError\).*does not exist' "$ERROR_FILE"; then
    echo "  existing stack: none"
  else
    cat "$ERROR_FILE" >&2
    die "[$region] could not inspect stack '$STACK_NAME'; refusing to deploy"
  fi

  detectors_json="$(aws guardduty list-detectors \
    --region "$region" \
    --output json)" || die "[$region] could not inspect GuardDuty detectors"
  detector_ids_text="$(python3 -c '
import json, sys
value = json.load(sys.stdin)
ids = value.get("DetectorIds")
if not isinstance(ids, list) or not all(isinstance(item, str) and item for item in ids):
    raise SystemExit("invalid DetectorIds response")
print(" ".join(ids))
' <<< "$detectors_json")" || die "[$region] could not parse GuardDuty detector inventory"
  detector_ids=()
  [[ -z "$detector_ids_text" ]] || read -r -a detector_ids <<< "$detector_ids_text"
  ((${#detector_ids[@]} <= 1)) ||
    die "[$region] GuardDuty returned multiple detectors, which this deployment cannot reconcile"
  existing_detector_id="${detector_ids[0]:-}"
  if [[ -n "$existing_detector_id" ]]; then
    echo "  existing detector: $existing_detector_id"
  else
    echo "  existing detector: none"
  fi

  managed_detector_id=""
  if [[ "$stack_exists" == true ]]; then
    resources_json="$(aws cloudformation list-stack-resources \
      --stack-name "$STACK_NAME" \
      --region "$region" \
      --output json)" || die "[$region] could not inspect resources in stack '$STACK_NAME'"
    managed_detector_id="$(python3 -c '
import json, sys
value = json.load(sys.stdin)
matches = [r for r in value.get("StackResourceSummaries", [])
           if r.get("LogicalResourceId") == "Detector"
           and r.get("ResourceType") == "AWS::GuardDuty::Detector"]
if len(matches) != 1 or not matches[0].get("PhysicalResourceId"):
    raise SystemExit(1)
print(matches[0]["PhysicalResourceId"])
' <<< "$resources_json")" ||
      die "[$region] stack '$STACK_NAME' does not contain the expected managed GuardDuty Detector resource; choose the correct STACK_NAME or reconcile the stack manually"
    [[ -n "$existing_detector_id" ]] ||
      die "[$region] stack '$STACK_NAME' records detector $managed_detector_id, but GuardDuty lists no detector; reconcile the failed/drifted stack manually"
    [[ "$managed_detector_id" == "$existing_detector_id" ]] ||
      die "[$region] stack '$STACK_NAME' manages detector $managed_detector_id, but GuardDuty lists $existing_detector_id; reconcile this drift manually"

    before_json="$(aws guardduty get-detector \
      --detector-id "$managed_detector_id" \
      --region "$region" \
      --output json)" || die "[$region] could not inspect managed detector $managed_detector_id"
    python3 -c '
import json, sys
value = json.load(sys.stdin)
features = ", ".join("{}={}".format(item.get("Name"), item.get("Status"))
                     for item in value.get("Features", []))
print("  before: Status={} FindingPublishingFrequency={} Features=[{}]".format(
    value.get("Status"), value.get("FindingPublishingFrequency"), features))
' <<< "$before_json" || die "[$region] could not parse managed detector details"
    echo "  action: update the existing managed stack (or confirm no changes)."
  elif [[ -n "$existing_detector_id" ]]; then
    die "[$region] detector $existing_detector_id already exists but is not managed by stack '$STACK_NAME'. This script will not adopt, replace, or ignore it. Reconcile explicitly: either keep/manage that detector outside this stack and do not run this deployment in $region, or deliberately remove it after evaluating findings/configuration loss and rerun to let CloudFormation create the detector."
  else
    echo "  action: create stack '$STACK_NAME' and its detector."
  fi

  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE" \
    --region "$region" \
    --no-fail-on-empty-changeset

  echo "  verifying stack, detector ownership, and foundational-only feature settings..."
  final_stack_status="$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$region" \
    --query 'Stacks[0].StackStatus' \
    --output text)" || die "[$region] could not verify stack '$STACK_NAME'"
  [[ "$final_stack_status" == "CREATE_COMPLETE" || "$final_stack_status" == "UPDATE_COMPLETE" ]] ||
    die "[$region] stack postcondition failed: status is $final_stack_status"

  final_resources_json="$(aws cloudformation list-stack-resources \
    --stack-name "$STACK_NAME" \
    --region "$region" \
    --output json)" || die "[$region] could not verify stack resources"
  final_detector_id="$(python3 -c '
import json, sys
value = json.load(sys.stdin)
matches = [r for r in value.get("StackResourceSummaries", [])
           if r.get("LogicalResourceId") == "Detector"
           and r.get("ResourceType") == "AWS::GuardDuty::Detector"
           and r.get("ResourceStatus") in ("CREATE_COMPLETE", "UPDATE_COMPLETE")]
if len(matches) != 1 or not matches[0].get("PhysicalResourceId"):
    raise SystemExit(1)
print(matches[0]["PhysicalResourceId"])
' <<< "$final_resources_json")" || die "[$region] detector stack-resource postcondition failed"

  final_detectors_json="$(aws guardduty list-detectors \
    --region "$region" \
    --output json)" || die "[$region] could not verify detector inventory"
  FINAL_DETECTOR_ID="$final_detector_id" python3 -c '
import json, os, sys
value = json.load(sys.stdin)
expected = os.environ["FINAL_DETECTOR_ID"]
ids = value.get("DetectorIds")
if ids != [expected]:
    print("expected exactly detector {}, got {}".format(expected, ids), file=sys.stderr)
    raise SystemExit(1)
' <<< "$final_detectors_json" || die "[$region] detector inventory postcondition failed"

  final_detector_json="$(aws guardduty get-detector \
    --detector-id "$final_detector_id" \
    --region "$region" \
    --output json)" || die "[$region] could not verify detector $final_detector_id"
  python3 -c '
import json, sys
value = json.load(sys.stdin)
errors = []
if value.get("Status") != "ENABLED":
    errors.append("Status={!r}".format(value.get("Status")))
if value.get("FindingPublishingFrequency") != "SIX_HOURS":
    errors.append("FindingPublishingFrequency={!r}".format(
        value.get("FindingPublishingFrequency")))
features = {f.get("Name"): f.get("Status") for f in value.get("Features", [])}
expected_disabled = {
    "S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION", "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS", "RUNTIME_MONITORING", "EKS_AUDIT_LOGS"
}
for name in sorted(expected_disabled):
    if features.get(name) != "DISABLED":
        errors.append("{}={!r}".format(name, features.get(name)))
if errors:
    print("unexpected detector configuration: " + ", ".join(errors), file=sys.stderr)
    raise SystemExit(1)
' <<< "$final_detector_json" || die "[$region] detector configuration postcondition failed"
  echo "  verified: stack=$final_stack_status detector=$final_detector_id status=ENABLED frequency=SIX_HOURS; all six optional features are DISABLED."
done

echo
echo "GuardDuty deployment and verification complete for account $EXPECTED_ACCOUNT_ID."
