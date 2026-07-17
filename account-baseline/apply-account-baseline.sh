#!/usr/bin/env bash
# Apply the non-CloudFormation account baseline. Run once per target account.
# Required environment:
#   EXPECTED_ACCOUNT_ID  12-digit account ID that the active credentials must use
#   CONTROL_REGION       explicit region for STS and the S3 Control API endpoint
# Optional environment:
#   REGIONS              whitespace-separated regions for EBS/IMDS defaults
#                        (defaults to the five landing-zone regions)
#
# Run this before attaching the baseline-security SCP. That SCP denies
# s3:PutAccountPublicAccessBlock and intentionally prevents later mutation.

set -euo pipefail

EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
CONTROL_REGION="${CONTROL_REGION:-}"
REGIONS="${REGIONS:-us-east-1 us-west-2 eu-central-1 eu-north-1 ap-southeast-1}"
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

read -r -a TARGET_REGIONS <<< "$REGIONS"
((${#TARGET_REGIONS[@]} > 0)) || die "REGIONS must contain at least one Region"
SEEN_REGIONS=" "
for region in "${TARGET_REGIONS[@]}"; do
  require_region "$region"
  [[ "$SEEN_REGIONS" != *" $region "* ]] || die "duplicate Region '$region' in REGIONS"
  SEEN_REGIONS+="$region "
done

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
echo "Control Region: $CONTROL_REGION"
echo "Per-Region settings: ${TARGET_REGIONS[*]}"
[[ "$CALLER_ACCOUNT" == "$EXPECTED_ACCOUNT_ID" ]] ||
  die "active credentials are for account $CALLER_ACCOUNT, not EXPECTED_ACCOUNT_ID $EXPECTED_ACCOUNT_ID; no changes were made"
case "$CALLER_ARN" in
  arn:aws:sts::*:assumed-role/AWSReservedSSO_LandingZoneAdmin_*/*|\
  arn:aws:sts::*:assumed-role/AWSReservedSSO_WorkloadAdmin_*/*) ;;
  *) die "baseline changes require a LandingZoneAdmin or WorkloadAdmin SSO role, not $CALLER_ARN" ;;
esac

echo
echo "[1/3] Inspecting S3 account-level Block Public Access..."
S3_WAS_ABSENT=false
if s3_before="$(aws s3control get-public-access-block \
    --account-id "$EXPECTED_ACCOUNT_ID" \
    --region "$CONTROL_REGION" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>"$ERROR_FILE")"; then
  read -r s3_a s3_b s3_c s3_d s3_extra <<< "$s3_before"
  [[ -n "${s3_a:-}" && -z "${s3_extra:-}" ]] || die "could not parse the existing S3 Block Public Access configuration"
  echo "      before: BlockPublicAcls=$s3_a IgnorePublicAcls=$s3_b BlockPublicPolicy=$s3_c RestrictPublicBuckets=$s3_d"
elif grep -q 'NoSuchPublicAccessBlockConfiguration' "$ERROR_FILE"; then
  S3_WAS_ABSENT=true
  s3_a=false; s3_b=false; s3_c=false; s3_d=false
  echo "      before: no account-level configuration"
else
  cat "$ERROR_FILE" >&2
  die "could not inspect S3 Block Public Access; refusing to mutate it"
fi

if [[ "$S3_WAS_ABSENT" == true || "$s3_a $s3_b $s3_c $s3_d" != "True True True True" ]]; then
  echo "      applying all four account-level blocks..."
  aws s3control put-public-access-block \
    --account-id "$EXPECTED_ACCOUNT_ID" \
    --region "$CONTROL_REGION" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
else
  echo "      already compliant; no mutation needed."
fi

s3_after="$(aws s3control get-public-access-block \
  --account-id "$EXPECTED_ACCOUNT_ID" \
  --region "$CONTROL_REGION" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text)" || die "could not verify S3 Block Public Access"
read -r s3_a s3_b s3_c s3_d s3_extra <<< "$s3_after"
[[ -z "${s3_extra:-}" && "$s3_a $s3_b $s3_c $s3_d" == "True True True True" ]] ||
  die "S3 Block Public Access postcondition failed (received: $s3_after)"
echo "      verified: all four account-level blocks are true."

for region in "${TARGET_REGIONS[@]}"; do
  echo
  echo "[2/3] [$region] Inspecting EBS encryption by default..."
  ebs_before="$(aws ec2 get-ebs-encryption-by-default \
    --region "$region" \
    --query EbsEncryptionByDefault \
    --output text)" || die "[$region] could not inspect EBS encryption by default"
  [[ "$ebs_before" == "True" || "$ebs_before" == "False" ]] ||
    die "[$region] unexpected EBS encryption state '$ebs_before'"
  echo "      before: EbsEncryptionByDefault=$ebs_before"
  if [[ "$ebs_before" != "True" ]]; then
    echo "      enabling..."
    aws ec2 enable-ebs-encryption-by-default --region "$region" >/dev/null
  else
    echo "      already compliant; no mutation needed."
  fi
  ebs_after="$(aws ec2 get-ebs-encryption-by-default \
    --region "$region" \
    --query EbsEncryptionByDefault \
    --output text)" || die "[$region] could not verify EBS encryption by default"
  [[ "$ebs_after" == "True" ]] ||
    die "[$region] EBS encryption postcondition failed (received: $ebs_after)"
  echo "      verified: EbsEncryptionByDefault=True."

  echo "[3/3] [$region] Inspecting account-level instance metadata defaults..."
  imds_before="$(aws ec2 get-instance-metadata-defaults \
    --region "$region" \
    --query 'AccountLevel.[HttpTokens,HttpEndpoint]' \
    --output text)" || die "[$region] could not inspect instance metadata defaults"
  read -r imds_tokens_before imds_endpoint_before imds_extra <<< "$imds_before"
  [[ ( "$imds_tokens_before" == "optional" || "$imds_tokens_before" == "required" ) &&
     ( "$imds_endpoint_before" == "enabled" || "$imds_endpoint_before" == "disabled" ) &&
     -z "${imds_extra:-}" ]] ||
    die "[$region] unexpected instance metadata defaults '$imds_before'"
  echo "      before: HttpTokens=$imds_tokens_before HttpEndpoint=$imds_endpoint_before"
  if [[ "$imds_tokens_before" != "required" ]]; then
    echo "      requiring IMDSv2 tokens without changing HttpEndpoint..."
    aws ec2 modify-instance-metadata-defaults \
      --region "$region" \
      --http-tokens required >/dev/null
  else
    echo "      tokens already required; no mutation needed."
  fi
  imds_after="$(aws ec2 get-instance-metadata-defaults \
    --region "$region" \
    --query 'AccountLevel.[HttpTokens,HttpEndpoint]' \
    --output text)" || die "[$region] could not verify instance metadata defaults"
  read -r imds_tokens_after imds_endpoint_after imds_extra <<< "$imds_after"
  [[ -z "${imds_extra:-}" && "$imds_tokens_after" == "required" ]] ||
    die "[$region] IMDS token postcondition failed (received: $imds_after)"
  [[ "$imds_endpoint_after" == "$imds_endpoint_before" ]] ||
    die "[$region] IMDS endpoint changed unexpectedly from $imds_endpoint_before to $imds_endpoint_after"
  echo "      verified: HttpTokens=required; HttpEndpoint remains $imds_endpoint_after."
done

echo
echo "Baseline verified for account $EXPECTED_ACCOUNT_ID."
echo "The management-account operator may now deploy/attach the SCP guardrails."
