# budget-alarms

One managed, organization-wide AWS Budget for a simple home Safety Net. It runs
in the Organizations management/payer account because that account sees
consolidated spend.

## Managed budget

| Name | Scope | Default limit | Notifications |
|---|---|---:|---|
| `paws-overall-monthly` | Entire organization | $20/month | Actual 25%, 50%, 75%; forecasted 50% |

There are deliberately no $5 Test or $2 Prod micro-budgets. The separate
[`cost-quarantine`](../cost-quarantine) component owns the high-threshold
linked-account actions: Test forecasted $50 and Prod actual $50.

Budget data is delayed and evaluated periodically. Alerts are a warning system,
not a real-time spending cap.

## Deploy

Use the management user's `LandingZoneAdmin` profile. The notification address
is a local deployment input and must not be committed.

```bash
export AWS_PROFILE=paws-mgmt-landing
./deploy.sh <notification-email>

# Optional limit override; the approved default is $20.
OVERALL_LIMIT=30 ./deploy.sh <notification-email>
```

The wrapper verifies the SSO role and Organizations management account before
CloudFormation runs. Budgets uses the `us-east-1` control-plane endpoint by
default even though the budget monitors consolidated global spend.

## Adopt or replace an existing budget without an alert gap

Do not infer ownership from a friendly name. Inventory the existing budget's
limit, notifications, and subscribers first:

```bash
MANAGEMENT_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
aws budgets describe-budgets --account-id "$MANAGEMENT_ACCOUNT_ID" --region us-east-1
aws budgets describe-notifications-for-budget \
  --account-id "$MANAGEMENT_ACCOUNT_ID" \
  --budget-name <existing-budget-name> \
  --region us-east-1
```

Decide explicitly whether differences from this repository's $20 and
25/50/75-actual plus 50-forecasted model should be corrected or preserved.
CloudFormation does not silently adopt an arbitrary existing budget. The safest
generic replacement is staged:

1. Deploy `paws-budget-alarms`, creating `paws-overall-monthly` first.
2. Query the live Budgets API to verify its limit, all four notifications, and
   intended subscriber; do not rely only on stack outputs.
3. Allow temporary coexistence long enough to prove the managed path and avoid
   an alert gap.
4. Delete the exact legacy budget only as a separately approved operation.

The deployment wrapper never deletes an old budget. After verification, an
authorized management operator can remove the chosen legacy name:

```bash
aws budgets delete-budget \
  --account-id "$MANAGEMENT_ACCOUNT_ID" \
  --budget-name <exact-legacy-budget-name> \
  --region us-east-1
```

Deletion is irreversible for that budget resource. Immediately verify that the
legacy name is absent and `paws-overall-monthly` still has its expected limit,
notifications, and subscriber.

## Local validation

```bash
cfn-lint cloudformation/budget-alarms.yaml
bash -n deploy.sh
```

## Files

```text
budget-alarms/
├── README.md
├── deploy.sh
└── cloudformation/
    └── budget-alarms.yaml
```
