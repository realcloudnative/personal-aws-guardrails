# cost-quarantine

A conservative, SCP-only home spend containment mechanism for both workload
accounts. It runs in the Organizations management account and uses native AWS
Budgets actions; billing delay means it is a damage limiter, not a real-time cap.

## Approved default behavior

```text
Test linked-account FORECASTED spend >= $50
  └─ automatic Budget action attaches home-cost-quarantine to Test

Prod linked-account ACTUAL spend >= $50
  └─ automatic Budget action attaches home-cost-quarantine to Prod
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

It creates **no** SNS topic, Lambda function, Step Functions state machine, log
group, management remediation role, or Test cross-account remediation role.
The deployment wrapper makes no workload-account API calls in this mode.

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

This runs `cfn-lint`, shell syntax checks, conditional-resource checks, and
static safety invariants. `shellcheck` is used when installed. It makes no AWS
calls.

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

The wrapper verifies the management role/account, both active workload
accounts, the identity-stack boundary output, and the offline invariants before
CloudFormation runs. Save both action IDs from the stack outputs.

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
undo operator mitigation. If the Budgets reversal API is unavailable, an
authorized management operator may detach the output SCP from the affected
account and then reconcile the Budget action history.

## Remediation is present but disabled

The existing Test-only SNS/Lambda/Standard Step Functions implementation remains
in the template behind `EnableRemediationResources`. It is not part of the
approved rollout and may be restructured later.

Only an explicit opt-in creates it:

```bash
# Not approved for the current rollout.
ENABLE_REMEDIATION=true \
  ./deploy.sh <test-account-id> <prod-account-id> <notification-email> <test-workload-profile>
```

That mode first deploys the separate Test remediation-role stack and then
creates the conditional management remediation resources. Do not use it until
the workflow has been reviewed and explicitly approved.

## Limitations

1. Budgets uses delayed billing data and may trigger hours after spend occurs.
2. Forecasts are estimates and can change sharply during a month.
3. Existing resources continue running in SCP-only mode; containment blocks
   selected new/start/invoke actions but does not stop anything.
4. Storage, snapshots, data transfer, Elastic IPs, NAT gateways, and other
   ongoing resources can continue charging until an operator acts.
5. Update APIs retained for shutdown compatibility can also scale resources up
   when a principal already has permission. Identity controls remain essential.
6. A reversed action should be reviewed before reset/reuse; do not assume a new
   billing period is an automatic operational release procedure.

## Files

| File | Default deployment | Purpose |
|---|---|---|
| `cloudformation/cost-quarantine.yaml` | Management | SCP, dual budgets/actions, conditional remediation |
| `cloudformation/test-remediation-role.yaml` | Not deployed | Optional Test remediation role |
| `deploy.sh` | Management only by default | Preflight and deployment wrapper |
| `validate.sh` | Local only | Offline lint and safety checks |
