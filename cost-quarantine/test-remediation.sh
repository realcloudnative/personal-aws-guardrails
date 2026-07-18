#!/usr/bin/env bash
# End-to-end test of the regional remediation state machine.
# Launches a t3.nano in the Test account, starts the state machine directly
# (bypassing EventBridge), then verifies the instance was stopped.
#
# Usage: ./test-remediation.sh
# Required environment:
#   AWS_PROFILE or MANAGEMENT_PROFILE  LandingZoneAdmin SSO profile
#   TEST_PROFILE                       WorkloadAdmin profile for Test account
# Optional environment:
#   REGION                             Region to test in (default eu-central-1)
#   TEST_ACCOUNT_ID                    default: discovered from TEST_PROFILE

set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

MANAGEMENT_PROFILE="${MANAGEMENT_PROFILE:-${AWS_PROFILE:-}}"
TEST_PROFILE="${TEST_PROFILE:?Set TEST_PROFILE to a WorkloadAdmin profile for Test}"
REGION="${REGION:-eu-central-1}"

[[ -n "$MANAGEMENT_PROFILE" ]] || fail "Set AWS_PROFILE or MANAGEMENT_PROFILE"

# Verify identities
printf 'Verifying identities...\n'
mgmt_account=$(aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" \
  sts get-caller-identity --query Account --output text)
test_account=$(aws --profile "$TEST_PROFILE" --region "$REGION" \
  sts get-caller-identity --query Account --output text)
TEST_ACCOUNT_ID="${TEST_ACCOUNT_ID:-$test_account}"
[[ "$test_account" == "$TEST_ACCOUNT_ID" ]] || fail "TEST_PROFILE resolves to $test_account, not $TEST_ACCOUNT_ID"
printf '  Management: %s\n  Test:       %s\n  Region:     %s\n' "$mgmt_account" "$test_account" "$REGION"

# Find the latest Amazon Linux 2023 AMI
printf 'Finding AMI...\n'
ami_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023*-x86_64" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
[[ "$ami_id" =~ ^ami- ]] || fail "could not find AMI"
printf '  AMI: %s\n' "$ami_id"

# Find a default VPC subnet (or any subnet)
subnet_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")
subnet_arg=()
if [[ "$subnet_id" != "None" && -n "$subnet_id" ]]; then
  subnet_arg=(--subnet-id "$subnet_id")
fi

# Launch a t3.nano instance
printf 'Launching t3.nano test instance...\n'
instance_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 run-instances \
  --image-id "$ami_id" \
  --instance-type t3.nano \
  --count 1 \
  "${subnet_arg[@]}" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true}}]' \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=quarantine-test},{Key=home:test,Value=remediation}]" \
  --query 'Instances[0].InstanceId' --output text)
[[ "$instance_id" =~ ^i- ]] || fail "failed to launch instance"
printf '  Instance: %s\n' "$instance_id"

# Wait for running
printf '  Waiting for running state...\n'
aws --profile "$TEST_PROFILE" --region "$REGION" ec2 wait instance-running \
  --instance-ids "$instance_id"
printf '  ✓ Instance is running\n'

# Start the regional state machine with targetAccountId
printf 'Starting regional state machine...\n'
sm_arn="arn:aws:states:${REGION}:${mgmt_account}:stateMachine:home-cost-quarantine-regional"
execution_arn=$(aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions start-execution \
  --state-machine-arn "$sm_arn" \
  --name "test-$(date +%s)" \
  --input "{\"targetAccountId\": \"$test_account\"}" \
  --query 'executionArn' --output text)
printf '  Execution: %s\n' "$execution_arn"

# Wait for completion
printf '  Waiting for state machine to complete...\n'
for i in $(seq 1 60); do
  status=$(aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query 'status' --output text)
  if [[ "$status" != "RUNNING" ]]; then
    break
  fi
  sleep 5
done
printf '  State machine status: %s\n' "$status"

if [[ "$status" != "SUCCEEDED" ]]; then
  printf '  Fetching error details...\n'
  aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query '[status,error,cause]' --output text
  # Still try to verify and clean up
fi

# Verify the instance was stopped
printf 'Verifying instance state...\n'
instance_state=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
printf '  Instance state: %s\n' "$instance_state"

if [[ "$instance_state" == "stopped" || "$instance_state" == "stopping" ]]; then
  printf '  ✓ PASS: Remediation successfully stopped the instance\n'
else
  printf '  ✗ FAIL: Instance is %s, expected stopped/stopping\n' "$instance_state"
fi

# Clean up: terminate the test instance
printf 'Cleaning up: terminating test instance...\n'
aws --profile "$TEST_PROFILE" --region "$REGION" ec2 terminate-instances \
  --instance-ids "$instance_id" --query 'TerminatingInstances[0].CurrentState.Name' --output text

printf '\nTest complete. State machine %s, instance %s.\n' "$status" "$instance_state"
[[ "$status" == "SUCCEEDED" && ("$instance_state" == "stopped" || "$instance_state" == "stopping") ]]
