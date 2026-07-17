# budget-alarms

One managed, organization-wide AWS Budget for a simple home Safety Net. It runs
in the Organizations management/payer account because that account sees
consolidated spend.

## Managed budget

| Name | Scope | Default limit | Notifications |
|---|---|---:|---|
| `home-overall-monthly` | Entire organization | $20/month | Actual 25%, 50%, 75%; forecasted 50% |

There are deliberately no $5 Test or $2 Prod micro-budgets. The separate
[`cost-quarantine`](../cost-quarantine) component owns the high-threshold
linked-account actions: Test forecasted $50 and Prod actual $50.

Budget data is delayed and evaluated periodically. Alerts are a warning system,
not a real-time spending cap.

## Deploy

Use the management user's `LandingZoneAdmin` profile. The notification address
is a local deployment input and must not be committed.

```bash
export AWS_PROFILE=home-mgmt-landing
./deploy.sh <notification-email>

# Optional limit override; the approved default is $20.
OVERALL_LIMIT=30 ./deploy.sh <notification-email>
```

The wrapper verifies the SSO role and Organizations management account before
CloudFormation runs. Budgets uses the `us-east-1` control-plane endpoint by
default even though the budget monitors consolidated global spend.

## Replace the existing unmanaged Safety Net without an alert gap

Reconciliation found an unmanaged budget named `Safety Net` with the approved
$20 limit and the same 25/50/75 actual plus 50 forecasted percentages.
CloudFormation cannot silently adopt it. Migration is deliberately staged:

1. Deploy `home-budget-alarms`, creating `home-overall-monthly` first.
2. Verify its $20 limit, all four notifications, and intended email subscriber.
3. Leave both budgets active long enough to confirm the managed alert path.
4. Separately delete `Safety Net` only after explicit authorization.

The deployment wrapper never deletes the old budget. An authorized management
operator can perform the final removal after verification:

```bash
MANAGEMENT_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
aws budgets delete-budget \
  --account-id "$MANAGEMENT_ACCOUNT_ID" \
  --budget-name "Safety Net" \
  --region us-east-1
```

Deletion is irreversible as a budget resource and is intentionally outside the
CloudFormation deployment.

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
