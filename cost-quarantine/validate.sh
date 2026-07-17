#!/usr/bin/env bash
# Offline validation only: no AWS API calls.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANAGEMENT_TEMPLATE="$ROOT_DIR/cloudformation/cost-quarantine.yaml"
TEST_TEMPLATE="$ROOT_DIR/cloudformation/test-remediation-role.yaml"

if ! command -v cfn-lint >/dev/null 2>&1; then
  echo "cfn-lint is required for offline validation." >&2
  exit 1
fi

cfn-lint "$MANAGEMENT_TEMPLATE" "$TEST_TEMPLATE"
bash -n "$ROOT_DIR/deploy.sh" "$ROOT_DIR/validate.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT_DIR/deploy.sh" "$ROOT_DIR/validate.sh"
else
  echo "note: shellcheck not installed; skipped shell validation" >&2
fi

if grep -Eqi 'arn:[^[:space:]]*:states:::aws-sdk:ssm:|AWS::SSM::' \
  "$MANAGEMENT_TEMPLATE" "$TEST_TEMPLATE"; then
  echo "validation failed: SSM is forbidden in cost quarantine" >&2
  exit 1
fi

if grep -Eqi 'Resource: .*aws-sdk:.*:(delete|terminate|remove)[A-Za-z]*|client\.(delete|terminate|remove)_[a-z_]+' \
  "$MANAGEMENT_TEMPLATE"; then
  echo "validation failed: destructive automatic SDK task or client call found" >&2
  exit 1
fi

if grep -Eq '^[[:space:]]+- ecs:UpdateService$' "$MANAGEMENT_TEMPLATE"; then
  echo "validation failed: containment SCP must not deny ecs:UpdateService" >&2
  exit 1
fi

python3 - "$MANAGEMENT_TEMPLATE" "$ROOT_DIR/deploy.sh" <<'PY'
from pathlib import Path
import re
import sys

template = Path(sys.argv[1]).read_text()
deploy = Path(sys.argv[2]).read_text()

required = (
    'Name: home-cost-quarantine',
    'Default: 50',
    'EnableRemediationResources: !Equals [!Ref EnableRemediation, "true"]',
    'ApprovalModel: AUTOMATIC',
    'PermissionsBoundary: !Ref QuarantineRoleBoundaryArn',
    'StateMachineType: STANDARD',
    'QueryLanguage: JSONata',
    'organizations:attachPolicy',
    'Organizations.DuplicatePolicyAttachmentException',
    'region_name=region',
    'assume_role(',
    'SourceAccount:',
    'SourceArn:',
    'ENABLE_REMEDIATION="${ENABLE_REMEDIATION:-false}"',
    'no workload-account calls and no Test remediation role deployment',
)
for marker in required:
    source = deploy if marker.startswith('ENABLE_REMEDIATION=') or marker.startswith('no workload') else template
    if marker not in source:
        raise SystemExit(f'validation failed: missing required marker: {marker}')

if len(re.findall(r'^    Type: AWS::Budgets::Budget$', template, re.MULTILINE)) != 2:
    raise SystemExit('validation failed: expected exactly two quarantine budgets')
if len(re.findall(r'^    Type: AWS::Budgets::BudgetsAction$', template, re.MULTILINE)) != 2:
    raise SystemExit('validation failed: expected exactly two quarantine actions')

def block(start, end):
    try:
        return template[template.index(start):template.index(end)]
    except ValueError as error:
        raise SystemExit(f'validation failed: missing block boundary: {error}')

test_action = block('  TestQuarantineAction:', '  ProdQuarantineAction:')
prod_action = block('  ProdQuarantineAction:', '  RemediationLogGroup:')
for value in ('NotificationType: FORECASTED', 'Value: !Ref TestQuarantineThreshold', 'TargetIds: [!Ref TestAccountId]'):
    if value not in test_action:
        raise SystemExit(f'validation failed: Test action missing {value}')
for value in ('NotificationType: ACTUAL', 'Value: !Ref ProdQuarantineThreshold', 'TargetIds: [!Ref ProdAccountId]'):
    if value not in prod_action:
        raise SystemExit(f'validation failed: Prod action missing {value}')

conditional_resources = (
    'BudgetNotificationTopic', 'BudgetNotificationTopicPolicy',
    'RemediationLogGroup', 'RegionalRemediatorExecutionRole', 'RegionalRemediator',
    'StateMachineExecutionRole', 'RemediationStateMachine', 'TriggerBridgeRole',
    'TriggerBridge', 'AllowSnsInvokeBridge', 'BridgeSubscription',
)
for name in conditional_resources:
    pattern = rf'^  {re.escape(name)}:\n    Type: [^\n]+\n    Condition: EnableRemediationResources$'
    if not re.search(pattern, template, re.MULTILINE):
        raise SystemExit(f'validation failed: {name} is not gated by EnableRemediationResources')

for name in ('TestQuarantineBudget', 'ProdQuarantineBudget', 'TestQuarantineAction', 'ProdQuarantineAction', 'QuarantineScp'):
    section_start = template.index(f'  {name}:')
    section_end = template.find('\n  ', section_start + 3)
    section = template[section_start: section_end if section_end != -1 else None]
    if 'Condition: EnableRemediationResources' in section:
        raise SystemExit(f'validation failed: core SCP-only resource {name} was accidentally conditioned off')

if re.search(r'^  QuarantineActionId:', template, re.MULTILINE) or re.search(r'^  BudgetName:', template, re.MULTILINE):
    raise SystemExit('validation failed: stale single-account quarantine outputs remain')
PY

printf 'Offline validation passed: CloudFormation lint and safety invariants.\n'
