# cost-quarantine

A conservative, SCP-only home spend containment mechanism for both workload
accounts. It runs in the Organizations management account and uses native AWS
Budgets actions; billing delay means it is a damage limiter, not a real-time cap.

## Approved default behavior

```text
Test linked-account FORECASTED spend >= $50
  └─ automatic Budget action attaches home-cost-quarantine SCP to Test

Prod linked-account ACTUAL spend >= $50
  └─ automatic Budget action attaches home-cost-quarantine SCP to Prod
```

The same generic SCP can be attached independently to either account. Each
Budget action has its own action ID and target. The SCP remains attached until an
operator manually reverses the corresponding action; there is no automatic
release.

With the default `EnableRemediation=false`, CloudFormation creates only:

- `home-cost-quarantine` SCP, initially unattached;
- one permissions-bounded Budgets execution role;
- Test $50 forecasted budget and automatic SCP action;
- Prod $50 actual budget and automatic SCP action.

It creates **no** EventBridge rules, Step Functions state machines, StackSets,
IAM execution roles, log groups, SNS topics, or Lambda functions.

## Optional multi-region remediation (`EnableRemediation=true`)

When enabled, the system automatically stops running resources in the Test
account after the SCP is attached. This is best-effort damage control:

```text
Budget action attaches SCP to Test account
  → CloudTrail logs ExecuteBudgetAction
  → EventBridge rule in us-east-1 matches the event
  → Rule forwards to the default bus in all 5 remediation Regions
  → Each Region's local EventBridge rule starts its state machine
  → State machine assumes the Test cross-account role
  → EC2: stop running instances
  → ASG: scale all groups to min=0, desired=0
  → ECS: scale all services to desiredCount=0
```

### Architecture (zero Lambda)

| Component | Location | Purpose |
|---|---|---|
| `cost-quarantine.yaml` | Management, us-east-1 | SCP, budgets, actions, EventBridge forwarding rule |
| `regional-remediation.yaml` | StackSet, all Regions | Per-region state machine, EventBridge rule, execution role, log group |
| `test-remediation-role.yaml` | Test account | Cross-account role with stop/scale-to-zero permissions |

The state machines use **Step Functions SDK integrations** with **JSONata** for
all data transformation. There are no Lambda functions, no JSONPath, and no
inline code anywhere in the remediation path.

Each regional state machine:
- Runs as `STANDARD` (up to 30 minutes per Region)
- Uses `Credentials: { RoleArn }` on every SDK Task for cross-account access
- Handles pagination via Choice states checking NextToken
- Catches and continues past individual stop/scale failures
- Has no delete, terminate, or remove permissions

### Why no RDS?

The service allowlist SCP already denies RDS creation. The quarantine SCP
additionally denies `rds:CreateDBInstance`, `rds:CreateDBCluster`,
`rds:StartDBInstance`, and `rds:StartDBCluster`. No RDS instances can exist in
the Test account under this SCP design, so no RDS remediation is needed.

## Containment policy

The SCP denies selected actions that can create or increase common spend,
including new/start compute, load balancers, NAT gateways, database creation or
start, ECS/EKS starts, Step Functions starts, metered AI inference (including
Bedrock Mantle), and selected paid batch jobs.

It deliberately does **not** deny stop, delete, terminate, remove,
describe/list/get, support, or billing actions. It also leaves mitigation update
APIs such as `ecs:UpdateService` and
`autoscaling:UpdateAutoScalingGroup` available. The policy never automatically
deletes a resource.

SCPs limit permissions but grant none. They do not restrict the management
account or AWS service-linked roles.

## Validate locally

```bash
./validate.sh
```

This runs `cfn-lint` on all three templates, shell syntax checks, Lambda/RDS/SSM
prohibitions, JSONPath prohibitions, conditional-resource gating, and structural
safety invariants. It makes no AWS calls.

## Deploy the approved SCP-only mode

Prerequisites:

- permanent Identity Center stack deployed in `eu-central-1` by default;
- `LandingZoneAdmin` SSO profile in management;
- active, distinct Test and Prod organization accounts;
- notification email supplied locally and never committed.

```bash
export AWS_PROFILE=home-mgmt-landing
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

This additionally requires a Test WorkloadAdmin profile:

```bash
ENABLE_REMEDIATION=true \
  ./deploy.sh <test-account-id> <prod-account-id> <notification-email> <test-sso-profile>
```

The wrapper will:
1. Deploy the Test cross-account role (via the Test profile).
2. Deploy the management stack with the EventBridge forwarding rule enabled.
3. Create or update the regional StackSet with state machines in all
   remediation Regions (via the management profile, self-managed StackSet
   targeting the management account in multiple Regions).

Monitor StackSet progress:

```bash
aws cloudformation list-stack-set-operations \
  --stack-set-name home-cost-quarantine-regional \
  --region us-east-1
```

## Manual release

Investigate the cost event first. To release one account, use that account's
budget name and action ID from the management stack outputs:

```bash
export AWS_PROFILE=home-mgmt-landing
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

## Files

| File | Deployment | Purpose |
|---|---|---|
| `cloudformation/cost-quarantine.yaml` | Management, us-east-1 | SCP, dual budgets/actions, conditional EventBridge forwarder |
| `cloudformation/regional-remediation.yaml` | StackSet, all Regions | Per-region state machine, EventBridge rule, execution role |
| `cloudformation/test-remediation-role.yaml` | Test account | Cross-account role for regional state machines |
| `deploy.sh` | Local | Preflight, deployment, and StackSet management |
| `validate.sh` | Local | Offline lint and safety checks |
