# cost-quarantine

Automatic SCP-based spend containment for both workload accounts, with optional
multi-region resource remediation. Runs in the Organizations management account
using native AWS Budgets actions. Billing delay means this is a damage limiter,
not a real-time spend cap.

## Default behavior (SCP-only)

```text
Test linked-account FORECASTED spend >= $50
  └─ automatic Budget action attaches paws-cost-quarantine SCP to Test

Prod linked-account ACTUAL spend >= $50
  └─ automatic Budget action attaches paws-cost-quarantine SCP to Prod
```

The same generic SCP can be attached independently to either account. Each
Budget action has its own action ID and target. The SCP remains attached until an
operator manually reverses the corresponding action; there is no automatic
release.

With the default `EnableRemediation=false`, CloudFormation creates only:

- `paws-cost-quarantine` SCP, initially unattached;
- one permissions-bounded Budgets execution role;
- Test $50 forecasted budget and automatic SCP action;
- Prod $50 actual budget and automatic SCP action.

No EventBridge rules, Step Functions state machines, StackSets, execution roles,
log groups, SNS topics, or Lambda functions are created.

## Optional multi-region remediation (`EnableRemediation=true`)

When enabled, the system automatically stops running resources in the triggered
account after the SCP is attached. This is best-effort damage control with zero
Lambda functions.

### Trigger chain

```text
Budget threshold exceeded
  → automatic SCP attachment to workload account
  → CloudTrail logs ExecuteBudgetAction in us-east-1
  → EventBridge rule in us-east-1 matches the event
  → Rule forwards to default bus in 4 other remediation Regions
  → Each Region's local EventBridge rule starts its state machine
  → State machine assumes cross-account remediation role
  → EC2: stop running instances
  → ASG: scale all groups to min=0, desired=0
  → ECS: scale all services to desiredCount=0
```

### Architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Management account                                                      │
│                                                                         │
│  us-east-1 (cost-quarantine.yaml)                                       │
│  ├─ Quarantine SCP                                                      │
│  ├─ Budget action role (bounded)                                        │
│  ├─ Test $50 forecasted budget + SCP action                             │
│  ├─ Prod $50 actual budget + SCP action                                 │
│  ├─ EventBridge forwarding rule (→ 4 other Region buses)                │
│  ├─ Global execution role (assumed by state machines)                   │
│  └─ Global trigger role (assumed by EventBridge)                        │
│                                                                         │
│  All 5 Regions (regional-remediation.yaml via self-managed StackSet)    │
│  ├─ State machine (JSONata, SDK integrations, dynamic Credentials)      │
│  ├─ EventBridge rule (starts state machine on forwarded event)          │
│  └─ Log group                                                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ Test + Prod accounts (test-remediation-role.yaml via service-managed    │
│                        StackSet, auto-deployment enabled)               │
│                                                                         │
│  paws-cost-quarantine-remediation role                                  │
│  ├─ Trusts management execution role                                    │
│  ├─ ec2:StopInstances, ec2:DescribeInstances                           │
│  ├─ autoscaling:DescribeAutoScalingGroups, UpdateAutoScalingGroup       │
│  └─ ecs:ListClusters, ListServices, UpdateService                      │
│                                                                         │
│  SCP-protected: workload admins cannot modify or delete this role       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Component summary

| Component | Stack / StackSet | Location | Purpose |
|---|---|---|---|
| `cost-quarantine.yaml` | `paws-cost-quarantine` stack | Management, us-east-1 | SCP, budgets, actions, conditional EventBridge forwarder + roles |
| `regional-remediation.yaml` | `paws-cost-quarantine-regional` self-managed StackSet | Management, all 5 Regions | Per-region state machine, EventBridge rule, log group |
| `test-remediation-role.yaml` | `paws-cost-quarantine-test-role` service-managed StackSet | Test + Prod OUs | Cross-account remediation role with auto-deployment |

### State machine design

Each regional state machine:

- Uses **Step Functions SDK integrations** with **JSONata** query language
- Accepts `targetAccountId` from the EventBridge event or direct invocation
- Uses `Credentials: { RoleArn }` on every SDK Task for cross-account access
- Handles pagination via Choice states checking NextToken
- Catches and continues past individual stop/scale failures
- Runs as `STANDARD` (supports up to 30 minutes per Region)
- Has no delete, terminate, or remove permissions

There are no Lambda functions, no JSONPath, and no inline code anywhere in the
remediation path.

### Why no RDS?

The service allowlist SCP already denies RDS creation. The quarantine SCP
additionally denies `rds:CreateDBInstance`, `rds:CreateDBCluster`,
`rds:StartDBInstance`, and `rds:StartDBCluster`. No RDS instances can exist in
workload accounts under this SCP design, so no RDS remediation is needed.

### SCP protection of the remediation role

The `ProtectQuarantineRemediationRole` statement in the baseline-security SCP
denies workload admins from modifying or deleting the
`paws-cost-quarantine-remediation` role. The service-managed StackSet execution
role (`stacksets-exec-*`) is exempted so CloudFormation can manage the role's
lifecycle. See [`scp-guardrails/README.md`](../scp-guardrails/README.md#quarantine-remediation-role-protection)
for details.

## Containment policy

The quarantine SCP uses a **blanket deny with surgical exceptions** (`NotAction`).
When attached, the account is frozen: no data-plane operations, no new resources,
no invocations, no Lambda executions, no S3 reads/writes.

Exceptions exist only for:
- **Remediation**: the state machine's stop/scale/disable/throttle actions
- **Investigation**: read-only CloudWatch, Cost Explorer, CloudFormation, tags
- **Support**: filing AWS support cases during the incident

This approach closes the gap where a selective denylist would miss services
(Lambda invocations through resource-based policies, DynamoDB reads, API Gateway
traffic, etc.).

### Remediation order

The state machine actively reduces compute in this sequence:

1. **ECS services → desired count 0** (disarms the ECS scheduler)
2. **ASG groups → desired capacity 0** (disarms the ASG controller)
3. **EC2 instances → stopped** (catches instances not behind controllers)
4. **EventBridge rules → disabled** (stops event-driven invocation sources)
5. **EventBridge Scheduler schedules → disabled** (stops scheduled invocations)
6. **Lambda functions → reserved concurrency 0** (blocks all invocations)

The order matters: event sources are disabled before Lambda is throttled, so no
new invocations are queued while concurrency is being reduced.

### Why Lambda needs active remediation

The quarantine SCP cannot stop EventBridge from invoking Lambda. EventBridge
invokes Lambda through a **resource-based policy** on the function, not through
an IAM role. SCPs only evaluate calls made by IAM principals, not service-to-
service invocations through resource policies. Setting reserved concurrency to 0
is the only way to stop a runaway EventBridge-to-Lambda feedback loop.

### Why EventBridge rules are disabled

Even with Lambda throttled, enabled rules still attempt invocations (which fail
and may retry). Disabling rules stops the invocation attempts entirely and
prevents any remaining targets (SNS, SQS, Step Functions) from being triggered.

SCPs limit permissions but grant none. They do not restrict the management
account or AWS service-linked roles.

## Validate locally

```bash
./validate.sh
```

Runs `cfn-lint` on all three templates, shell syntax checks, Lambda/RDS/SSM
prohibitions, JSONPath prohibitions, conditional-resource gating, and structural
safety invariants. Makes no AWS calls.

## Deploy the default SCP-only mode

Prerequisites:

- permanent Identity Center stack deployed;
- `LandingZoneAdmin` SSO profile in management;
- active, distinct Test and Prod organization accounts;
- notification email supplied locally and never committed.

```bash
export AWS_PROFILE=paws-mgmt-landing
./deploy.sh <test-account-id> <prod-account-id> <notification-email>
```

Defaults:

```text
REGION=us-east-1
IDENTITY_REGION=eu-central-1
TEST_QUARANTINE_THRESHOLD=50       # FORECASTED
PROD_QUARANTINE_THRESHOLD=50       # ACTUAL
ENABLE_REMEDIATION=false
```

## Deploy with multi-region remediation

Additional prerequisites:

- StackSet bootstrap roles deployed (`AWSCloudFormationStackSetAdministrationRole`
  + `AWSCloudFormationStackSetExecutionRole` via `paws-stackset-bootstrap` stack)
- Organizations trusted access for CloudFormation StackSets enabled
- `LandingZoneAdmin` permissions include: `events:PutRule`, `events:PutTargets`,
  `iam:CreateRole` for quarantine roles, `iam:PassRole` to events/states/budgets
  services
- A workload SSO profile (`WorkloadAdmin`) for the Test account

```bash
ENABLE_REMEDIATION=true \
  ./deploy.sh <test-account-id> <prod-account-id> <notification-email> <test-sso-profile>
```

The wrapper will:

1. Deploy the management stack with the EventBridge forwarding rule and roles
   enabled (via `LandingZoneAdmin`).
2. Create or update the service-managed StackSet deploying the cross-account
   remediation role to both Test and Prod OUs (auto-deployment enabled for new
   accounts).
3. Create or update the self-managed StackSet deploying regional state machines
   to the management account in all 5 remediation Regions.

Monitor StackSet progress:

```bash
aws cloudformation list-stack-set-operations \
  --stack-set-name paws-cost-quarantine-regional \
  --region us-east-1
```

## Testing remediation

`test-remediation.sh` exercises the state machine without waiting for a budget
trigger:

```bash
export AWS_PROFILE=paws-mgmt-landing
./test-remediation.sh <test-account-id> <test-sso-profile>
```

The script:

1. Launches a `t3.nano` in the Test account (via the workload profile).
2. Directly starts the regional state machine with `targetAccountId` input.
3. Polls until the state machine completes.
4. Verifies the instance is stopped.
5. Terminates the instance.

This validates the full cross-account remediation path without triggering the
budget or attaching the SCP.

## Manual release

Investigate the cost event first. To release one account, use that account's
budget name and action ID from the management stack outputs:

```bash
export AWS_PROFILE=paws-mgmt-landing
MANAGEMENT_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

aws budgets execute-budget-action \
  --account-id "$MANAGEMENT_ACCOUNT_ID" \
  --budget-name <TestBudgetName-or-ProdBudgetName> \
  --action-id <matching-action-id> \
  --execution-type REVERSE_BUDGET_ACTION \
  --region us-east-1
```

This detaches the SCP for the selected action. It does not restart anything or
undo operator mitigation. The regional state machines are idempotent; if they
re-trigger on the same budget period, they will attempt to stop resources that
may have already been stopped.

## Testing without a budget trigger

`test-remediation.sh` proves the full state machine path without waiting for a
real budget threshold. It launches a t3.nano in the Test account, starts the
regional state machine directly with `targetAccountId` as input, verifies the
instance is stopped, and terminates it.

```bash
AWS_PROFILE=paws-mgmt-landing TEST_PROFILE=paws-test-admin \
  ./test-remediation.sh
```

The default test Region is `eu-central-1`. Override with `REGION=us-east-1`.

Requirements:
- Both management and workload SSO sessions active (separate users/browsers)
- `LandingZoneAdmin` needs `states:StartExecution` on `paws-cost-quarantine-*`
- Test launches must comply with active SCPs: IMDSv2 required, EBS encryption
  required, instance size ≤ small

To test the full EventBridge trigger chain (attaches the SCP and fires all 5
regional state machines), manually execute the budget action:

```bash
AWS_PROFILE=paws-mgmt-landing
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
aws budgets execute-budget-action \
  --account-id "$ACCOUNT_ID" \
  --budget-name paws-cost-quarantine-test \
  --action-id <test-action-id-from-stack-outputs> \
  --execution-type EXECUTE_BUDGET_ACTION \
  --region us-east-1
```

This is a real quarantine: it attaches the SCP immediately. Use
`REVERSE_BUDGET_ACTION` to release afterward.

## Limitations

1. Budgets uses delayed billing data and may trigger hours after spend occurs.
2. Forecasts are estimates and can change sharply during a month.
3. Existing resources continue running until the state machines stop them;
   containment blocks selected new/start/invoke actions immediately.
4. Storage, snapshots, data transfer, Elastic IPs, NAT gateways, and other
   ongoing resources continue charging until an operator acts.
5. Update APIs retained for shutdown compatibility can also scale resources up
   when a principal already has permission. Identity controls remain essential.
6. Cross-region EventBridge forwarding is best-effort via CloudTrail; there
   may be a delay of seconds to minutes between the SCP attachment and
   regional state machine execution.
7. Step Functions SDK integrations cannot make cross-region calls; each
   regional state machine only remediates resources in its own Region.
8. The service-managed StackSet targets both Test and Prod OUs; the
   remediation role exists in all workload accounts regardless of which
   account triggered quarantine.

## Files

| File | Deployment | Purpose |
|---|---|---|
| `cloudformation/cost-quarantine.yaml` | Management stack, us-east-1 | SCP, dual budgets/actions, conditional EventBridge forwarder + roles |
| `cloudformation/regional-remediation.yaml` | Self-managed StackSet, all 5 Regions | Per-region state machine, EventBridge rule, log group |
| `cloudformation/test-remediation-role.yaml` | Service-managed StackSet, Test + Prod OUs | Cross-account remediation role (auto-deployment) |
| `deploy.sh` | Local | Preflight, deployment, and StackSet management |
| `validate.sh` | Local | Offline lint and safety checks |
| `test-remediation.sh` | Local | End-to-end remediation test without budget trigger |
