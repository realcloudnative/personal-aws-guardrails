#!/usr/bin/env bash
# Offline validation only: no AWS API calls.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANAGEMENT_TEMPLATE="$ROOT_DIR/cloudformation/cost-quarantine.yaml"
TEST_TEMPLATE="$ROOT_DIR/cloudformation/test-remediation-role.yaml"
REGIONAL_TEMPLATE="$ROOT_DIR/cloudformation/regional-remediation.yaml"

if ! command -v cfn-lint >/dev/null 2>&1; then
  echo "cfn-lint is required for offline validation." >&2
  exit 1
fi

cfn-lint "$MANAGEMENT_TEMPLATE" "$TEST_TEMPLATE" "$REGIONAL_TEMPLATE"
bash -n "$ROOT_DIR/deploy.sh" "$ROOT_DIR/validate.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT_DIR/deploy.sh" "$ROOT_DIR/validate.sh"
else
  echo "note: shellcheck not installed; skipped shell validation" >&2
fi

# Safety: no SSM automation
if grep -Eqi 'arn:[^[:space:]]*:states:::aws-sdk:ssm:|AWS::SSM::' \
  "$MANAGEMENT_TEMPLATE" "$TEST_TEMPLATE" "$REGIONAL_TEMPLATE"; then
  echo "validation failed: SSM is forbidden in cost quarantine" >&2
  exit 1
fi

# Safety: no destructive SDK tasks in the regional state machine
if grep -Eqi 'aws-sdk:.*:(delete|terminate|remove)[A-Za-z]*' "$REGIONAL_TEMPLATE"; then
  echo "validation failed: destructive SDK task found in regional template" >&2
  exit 1
fi

# Safety: containment SCP must not deny ecs:UpdateService (needed for remediation)
if grep -Eq '^[[:space:]]+- ecs:UpdateService$' "$MANAGEMENT_TEMPLATE"; then
  echo "validation failed: containment SCP must not deny ecs:UpdateService" >&2
  exit 1
fi

# Safety: no Lambda functions anywhere
if grep -Eqi 'AWS::Lambda::Function|AWS::Lambda::Permission|lambda:invoke|lambda\.amazonaws\.com' \
  "$MANAGEMENT_TEMPLATE" "$REGIONAL_TEMPLATE"; then
  echo "validation failed: Lambda resources are forbidden in this architecture" >&2
  exit 1
fi

# Safety: no JSONPath in state machine (no $. references, no Parameters/ResultPath/InputPath/OutputPath)
if grep -Eq '"Parameters"|ResultPath|InputPath|OutputPath|ResultSelector' "$REGIONAL_TEMPLATE"; then
  echo "validation failed: JSONPath I/O fields found in regional template" >&2
  exit 1
fi

# Safety: no RDS in remediation role
if grep -Eqi 'rds:|DBInstance|DBCluster' "$TEST_TEMPLATE"; then
  echo "validation failed: RDS references found in test remediation role" >&2
  exit 1
fi

python3 - "$MANAGEMENT_TEMPLATE" "$REGIONAL_TEMPLATE" "$ROOT_DIR/deploy.sh" <<'PY'
from pathlib import Path
import re
import sys

mgmt = Path(sys.argv[1]).read_text()
regional = Path(sys.argv[2]).read_text()
deploy = Path(sys.argv[3]).read_text()

# Management template markers
mgmt_required = (
    'Name: home-cost-quarantine',
    'Default: 50',
    'EnableRemediationResources: !Equals [!Ref EnableRemediation, "true"]',
    'ApprovalModel: AUTOMATIC',
    'PermissionsBoundary: !Ref QuarantineRoleBoundaryArn',
    'ExecuteBudgetAction',
    'events:PutEvents',
)
for marker in mgmt_required:
    if marker not in mgmt:
        raise SystemExit(f'validation failed: management template missing: {marker}')

# Regional template markers
regional_required = (
    'QueryLanguage: JSONata',
    'StateMachineType: STANDARD',
    'Credentials:',
    'aws-sdk:ec2:stopInstances',
    'aws-sdk:autoscaling:updateAutoScalingGroup',
    'aws-sdk:ecs:updateService',
    'aws-sdk:ecs:listClusters',
    'aws-sdk:ecs:listServices',
    'aws-sdk:ec2:describeInstances',
    'PermissionsBoundary: !Ref QuarantineRoleBoundaryArn',
)
for marker in regional_required:
    if marker not in regional:
        raise SystemExit(f'validation failed: regional template missing: {marker}')

# Deploy script markers
deploy_required = (
    'ENABLE_REMEDIATION="${ENABLE_REMEDIATION:-false}"',
    'regional-remediation.yaml',
    'create-stack-set',
    'create-stack-instances',
)
for marker in deploy_required:
    if marker not in deploy:
        raise SystemExit(f'validation failed: deploy.sh missing: {marker}')

# Budget structure
if len(re.findall(r'^    Type: AWS::Budgets::Budget$', mgmt, re.MULTILINE)) != 2:
    raise SystemExit('validation failed: expected exactly two quarantine budgets')
if len(re.findall(r'^    Type: AWS::Budgets::BudgetsAction$', mgmt, re.MULTILINE)) != 2:
    raise SystemExit('validation failed: expected exactly two quarantine actions')

# Conditional gating
conditional_resources = ('EventForwardingRole', 'EventForwardingRule')
for name in conditional_resources:
    pattern = rf'^  {re.escape(name)}:\n    Type: [^\n]+\n    Condition: EnableRemediationResources$'
    if not re.search(pattern, mgmt, re.MULTILINE):
        raise SystemExit(f'validation failed: {name} not gated by EnableRemediationResources')

# Core resources must NOT be conditional
for name in ('TestQuarantineBudget', 'ProdQuarantineBudget', 'TestQuarantineAction', 'ProdQuarantineAction', 'QuarantineScp'):
    section_start = mgmt.index(f'  {name}:')
    section_end = mgmt.find('\n  ', section_start + 3)
    section = mgmt[section_start: section_end if section_end != -1 else None]
    if 'Condition: EnableRemediationResources' in section:
        raise SystemExit(f'validation failed: core resource {name} was accidentally conditioned off')

# JSONata must be in regional template, not JSONPath
if re.search(r'"\$\.', regional):
    # Allow EventBridge InputPathsMap $.detail syntax but not in state machine
    # The regional template should have no EventBridge InputTransformer
    lines_with_dollar = [l for l in regional.splitlines() if '"$.' in l and 'InputPathsMap' not in l]
    if lines_with_dollar:
        raise SystemExit(f'validation failed: possible JSONPath in regional template: {lines_with_dollar[0]}')
PY

printf 'Offline validation passed: CloudFormation lint and safety invariants.\n'
