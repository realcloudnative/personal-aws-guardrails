#!/usr/bin/env bash
# Full remediation test: ECS service, ASG, and standalone EC2 in one run.
# Proves the state machine correctly scales ECS to 0, ASG to 0, and stops EC2.
#
# Usage: ./test-remediation-full.sh
# Required environment:
#   AWS_PROFILE or MANAGEMENT_PROFILE  LandingZoneAdmin SSO profile
#   TEST_PROFILE                       WorkloadAdmin profile for Test account
# Optional environment:
#   REGION                             Region to test in (default eu-central-1)

set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  printf '\nCleaning up...\n'
  # Best-effort cleanup in reverse order
  if [[ -n "${lambda_name:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" lambda delete-function \
      --function-name "$lambda_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "${rule_name:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" events remove-targets \
      --rule "$rule_name" --ids target1 >/dev/null 2>&1 || true
    aws --profile "$TEST_PROFILE" --region "$REGION" events delete-rule \
      --name "$rule_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "${lambda_role_arn:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" iam delete-role-policy \
      --role-name "$lambda_role_name" --policy-name inline >/dev/null 2>&1 || true
    aws --profile "$TEST_PROFILE" --region "$REGION" iam delete-role \
      --role-name "$lambda_role_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "${service_arn:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" ecs delete-service \
      --cluster "$cluster_arn" --service "$service_arn" --force >/dev/null 2>&1 || true
  fi
  if [[ -n "${cluster_arn:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" ecs delete-cluster \
      --cluster "$cluster_arn" >/dev/null 2>&1 || true
  fi
  if [[ -n "${asg_name:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name "$asg_name" --force-delete >/dev/null 2>&1 || true
  fi
  if [[ -n "${lt_name:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" ec2 delete-launch-template \
      --launch-template-name "$lt_name" >/dev/null 2>&1 || true
  fi
  if [[ -n "${instance_id:-}" ]]; then
    aws --profile "$TEST_PROFILE" --region "$REGION" ec2 terminate-instances \
      --instance-ids "$instance_id" >/dev/null 2>&1 || true
  fi
  printf 'Cleanup complete.\n'
}
trap cleanup EXIT

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
printf '  Management: %s\n  Test:       %s\n  Region:     %s\n' "$mgmt_account" "$test_account" "$REGION"

# Find AMI and subnet
ami_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
[[ "$ami_id" =~ ^ami- ]] || fail "could not find AMI"

subnet_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None")
az=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo "")

printf '  AMI: %s  Subnet: %s\n\n' "$ami_id" "$subnet_id"

# Unique suffix to avoid collisions with draining resources
ts=$(date +%s)
cluster_name="quarantine-test-${ts}"
service_name="quarantine-test-svc-${ts}"

# --- 1. Create ECS cluster + Fargate service ---
printf '1. Creating ECS Fargate service...\n'
cluster_arn=$(aws --profile "$TEST_PROFILE" --region "$REGION" ecs create-cluster \
  --cluster-name "$cluster_name" --query 'cluster.clusterArn' --output text)
printf '   Cluster: %s\n' "$cluster_arn"

# Register a minimal task definition (no actual container needed for the test)
task_def_arn=$(aws --profile "$TEST_PROFILE" --region "$REGION" ecs register-task-definition \
  --family "quarantine-test-${ts}" \
  --requires-compatibilities FARGATE \
  --network-mode awsvpc \
  --cpu 256 --memory 512 \
  --container-definitions '[{"name":"dummy","image":"public.ecr.aws/docker/library/alpine:3.19","essential":true,"command":["sleep","3600"]}]' \
  --query 'taskDefinition.taskDefinitionArn' --output text)
printf '   Task def: %s\n' "$task_def_arn"

service_arn=$(aws --profile "$TEST_PROFILE" --region "$REGION" ecs create-service \
  --cluster "$cluster_name" \
  --service-name "$service_name" \
  --task-definition "quarantine-test-${ts}" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnet_id],assignPublicIp=ENABLED}" \
  --query 'service.serviceArn' --output text)
printf '   Service: %s (desired=1)\n' "$service_arn"

# --- 2. Create ASG with 1 instance ---
printf '2. Creating ASG with 1 instance...\n'
lt_name="quarantine-test-lt-${ts}"
asg_name="quarantine-test-asg-${ts}"

lt_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 create-launch-template \
  --launch-template-name "$lt_name" \
  --launch-template-data "{
    \"ImageId\": \"$ami_id\",
    \"InstanceType\": \"t3.nano\",
    \"MetadataOptions\": {\"HttpTokens\": \"required\", \"HttpEndpoint\": \"enabled\"},
    \"BlockDeviceMappings\": [{\"DeviceName\": \"/dev/xvda\", \"Ebs\": {\"VolumeSize\": 8, \"Encrypted\": true}}]
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
printf '   Launch template: %s\n' "$lt_id"

aws --profile "$TEST_PROFILE" --region "$REGION" autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$asg_name" \
  --launch-template "LaunchTemplateId=$lt_id,Version=\$Latest" \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --availability-zones "$az" \
  --tags "Key=Name,Value=quarantine-test-asg,PropagateAtLaunch=true"
printf '   ASG: %s (desired=1)\n' "$asg_name"

# --- 3. Launch standalone EC2 ---
printf '3. Launching standalone EC2...\n'
subnet_arg=()
[[ "$subnet_id" != "None" ]] && subnet_arg=(--subnet-id "$subnet_id")
instance_id=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 run-instances \
  --image-id "$ami_id" \
  --instance-type t3.nano \
  --count 1 \
  "${subnet_arg[@]}" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true}}]' \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=quarantine-test-standalone}]" \
  --query 'Instances[0].InstanceId' --output text)
printf '   Instance: %s\n' "$instance_id"

# --- 4. Create Lambda function ---
printf '4. Creating Lambda function...\n'
lambda_name="quarantine-test-fn-${ts}"
lambda_role_name="quarantine-test-lambda-role-${ts}"

lambda_role_arn=$(aws --profile "$TEST_PROFILE" --region "$REGION" iam create-role \
  --role-name "$lambda_role_name" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query 'Role.Arn' --output text)
aws --profile "$TEST_PROFILE" --region "$REGION" iam put-role-policy \
  --role-name "$lambda_role_name" --policy-name inline \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"logs:*","Resource":"*"}]}'
printf '   Lambda role: %s\n' "$lambda_role_arn"
sleep 10  # wait for role propagation

aws --profile "$TEST_PROFILE" --region "$REGION" lambda create-function \
  --function-name "$lambda_name" \
  --runtime python3.12 \
  --role "$lambda_role_arn" \
  --handler index.handler \
  --zip-file fileb://<(python3 -c "
import zipfile, io
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as z:
    z.writestr('index.py', 'def handler(event, context): return {\"status\": \"ok\"}')
import sys; sys.stdout.buffer.write(buf.getvalue())
") \
  --timeout 10 --memory-size 128 >/dev/null
printf '   Function: %s\n' "$lambda_name"

# --- 5. Create EventBridge rule ---
printf '5. Creating EventBridge rule...\n'
rule_name="quarantine-test-rule-${ts}"
aws --profile "$TEST_PROFILE" --region "$REGION" events put-rule \
  --name "$rule_name" \
  --schedule-expression "rate(1 hour)" \
  --state ENABLED >/dev/null
aws --profile "$TEST_PROFILE" --region "$REGION" events put-targets \
  --rule "$rule_name" \
  --targets "[{\"Id\":\"target1\",\"Arn\":\"arn:aws:lambda:${REGION}:${test_account}:function:${lambda_name}\"}]" >/dev/null
printf '   Rule: %s (ENABLED)\n' "$rule_name"

# --- Wait for resources to stabilize ---
printf '\nWaiting for ASG instance and standalone EC2 to reach running...\n'
aws --profile "$TEST_PROFILE" --region "$REGION" ec2 wait instance-running --instance-ids "$instance_id"
# Wait for ASG instance
for i in $(seq 1 30); do
  asg_instances=$(aws --profile "$TEST_PROFILE" --region "$REGION" autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg_name" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`] | length(@)' --output text)
  [[ "$asg_instances" -ge 1 ]] && break
  sleep 10
done
printf '  ✓ ASG has %s InService instance(s)\n' "$asg_instances"
printf '  ✓ Standalone EC2 running\n'

# --- Run the state machine ---
printf '\nStarting regional state machine...\n'
sm_arn="arn:aws:states:${REGION}:${mgmt_account}:stateMachine:paws-cost-quarantine-regional"
execution_arn=$(aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions start-execution \
  --state-machine-arn "$sm_arn" \
  --name "full-test-$(date +%s)" \
  --input "{\"targetAccountId\": \"$test_account\"}" \
  --query 'executionArn' --output text)
printf '  Execution: %s\n' "$execution_arn"

printf '  Waiting for completion...\n'
for i in $(seq 1 90); do
  status=$(aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query 'status' --output text)
  [[ "$status" != "RUNNING" ]] && break
  sleep 5
done
printf '  State machine: %s\n' "$status"

if [[ "$status" != "SUCCEEDED" ]]; then
  aws --profile "$MANAGEMENT_PROFILE" --region "$REGION" stepfunctions describe-execution \
    --execution-arn "$execution_arn" --query '[error,cause]' --output text
fi

# --- Verify results ---
printf '\nVerifying results...\n'
pass=true

# ECS service desired count
ecs_desired=$(aws --profile "$TEST_PROFILE" --region "$REGION" ecs describe-services \
  --cluster "$cluster_name" --services "$service_name" \
  --query 'services[0].desiredCount' --output text)
printf '  ECS service desired count: %s ' "$ecs_desired"
if [[ "$ecs_desired" == "0" ]]; then printf '✓\n'; else printf '✗ (expected 0)\n'; pass=false; fi

# ASG desired capacity
asg_desired=$(aws --profile "$TEST_PROFILE" --region "$REGION" autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$asg_name" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
printf '  ASG desired capacity: %s ' "$asg_desired"
if [[ "$asg_desired" == "0" ]]; then printf '✓\n'; else printf '✗ (expected 0)\n'; pass=false; fi

# Standalone EC2 state
ec2_state=$(aws --profile "$TEST_PROFILE" --region "$REGION" ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
printf '  Standalone EC2 state: %s ' "$ec2_state"
if [[ "$ec2_state" == "stopped" || "$ec2_state" == "stopping" ]]; then printf '✓\n'; else printf '✗ (expected stopped/stopping)\n'; pass=false; fi

# EventBridge rule state
rule_state=$(aws --profile "$TEST_PROFILE" --region "$REGION" events describe-rule \
  --name "$rule_name" --query 'State' --output text)
printf '  EventBridge rule state: %s ' "$rule_state"
if [[ "$rule_state" == "DISABLED" ]]; then printf '✓\n'; else printf '✗ (expected DISABLED)\n'; pass=false; fi

# Lambda reserved concurrency
lambda_concurrency=$(aws --profile "$TEST_PROFILE" --region "$REGION" lambda get-function-concurrency \
  --function-name "$lambda_name" --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || echo "None")
printf '  Lambda reserved concurrency: %s ' "$lambda_concurrency"
if [[ "$lambda_concurrency" == "0" ]]; then printf '✓\n'; else printf '✗ (expected 0)\n'; pass=false; fi

if [[ "$pass" == "true" && "$status" == "SUCCEEDED" ]]; then
  printf '\n✓ FULL PASS: All resource types remediated correctly.\n'
else
  printf '\n✗ PARTIAL FAIL: State machine %s. Check results above.\n' "$status"
  exit 1
fi
