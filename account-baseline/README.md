# account-baseline

Turns **on** security settings that the SCPs in [`../scp-guardrails`](../scp-guardrails) later lock. SCPs can prevent settings from being weakened, but cannot enable them. This directory contains the per-account baseline; it does not deploy SCPs.

## Scope and behavior

| Setting | Exact scope | Mechanism | Behavior |
|---|---|---|---|
| S3 account Block Public Access | Once per account (global setting) | CLI through the explicit `CONTROL_REGION` endpoint | Inspects first, then sets all four account flags to `true`, and reads them back |
| EBS encryption by default | Each Region in `REGIONS` in the expected account | CLI | Enables only when needed and reads back `EbsEncryptionByDefault=True` |
| EC2 instance metadata defaults | Each Region in `REGIONS` in the expected account | CLI | Requires IMDSv2 tokens for future launches that inherit account defaults; preserves the existing `HttpEndpoint` value and verifies it did not change |
| GuardDuty detector *(optional)* | Exactly one selected Region per account | CloudFormation | Defaults to `us-east-1` for management and `eu-central-1` for workloads; refuses deployment while another enabled detector is found in an inspected Region |

Every script requires `EXPECTED_ACCOUNT_ID` and refuses to mutate when the STS caller belongs to another account. It prints the caller ARN, caller/expected account IDs, and explicit `CONTROL_REGION`. No account IDs are embedded in this repository.

`CONTROL_REGION` removes dependence on ambient CLI configuration. The baseline script uses it for STS and the regional S3 Control endpoint; S3 account Block Public Access remains an account-global setting. The GuardDuty script uses it for STS and uses its independently selected `GUARDDUTY_REGION` for CloudFormation and GuardDuty.

## Run order and account responsibilities

Run `apply-account-baseline.sh` **before** the management-account operator attaches `home-guardrail-baseline-security`:

```text
1. account-baseline in each account  ──►  2. SCP deployment/attachment from management
   (enable and verify settings)             (lock member-account settings)
```

The baseline-security SCP denies `s3:PutAccountPublicAccessBlock`. Attaching it first can prevent account-level S3 Block Public Access from being enabled. EBS and IMDS settings do not have that ordering dependency.

Run the account baseline separately with credentials for management, Test, and Prod. **Do not deploy `scp-guardrails` from each account.** Its CloudFormation deployment and Organizations policy attachment are management-account-only. The management account is not affected by SCPs, but applying these account baseline settings there is still useful hygiene.

## Required inputs and usage

Use an explicit, externally supplied 12-digit account ID. Replace shell placeholders with your own values; do not commit IDs.

```bash
# Always-on preventive settings. By default, EBS and IMDS are handled in all
# five landing-zone Regions; S3 BPA is handled once for the account.
EXPECTED_ACCOUNT_ID="$TARGET_ACCOUNT_ID" \
CONTROL_REGION="us-east-1" \
AWS_PROFILE="home-test-admin" \
./apply-account-baseline.sh

# Limit only the per-Region EBS and IMDS work.
EXPECTED_ACCOUNT_ID="$TARGET_ACCOUNT_ID" \
CONTROL_REGION="eu-central-1" \
REGIONS="eu-central-1" \
AWS_PROFILE="home-test-admin" \
./apply-account-baseline.sh
```

GuardDuty remains optional: invoking its separate wrapper is the opt-in. The wrapper requires `ACCOUNT_TYPE`, selects exactly one Region, and verifies that the caller role matches the account type:

```bash
# Management account: defaults to us-east-1 and requires LandingZoneAdmin.
EXPECTED_ACCOUNT_ID="$MANAGEMENT_ACCOUNT_ID" \
CONTROL_REGION="us-east-1" \
ACCOUNT_TYPE="management" \
AWS_PROFILE="home-mgmt-landing" \
./deploy-guardduty.sh

# Test or Prod: defaults to eu-central-1 and requires WorkloadAdmin.
EXPECTED_ACCOUNT_ID="$WORKLOAD_ACCOUNT_ID" \
CONTROL_REGION="eu-central-1" \
ACCOUNT_TYPE="workload" \
AWS_PROFILE="home-test-admin" \
./deploy-guardduty.sh
```

`GUARDDUTY_REGION` can override the account-type default when deliberately needed. `INSPECTION_REGIONS` defaults to the five landing-zone Regions and is only used to detect other enabled detectors; it does not deploy anything there.

The scripts inspect each setting before mutation, skip compliant settings, verify every postcondition, and return nonzero if inspection, mutation, or verification fails. Re-running against a healthy managed baseline is safe.

A failure can occur after valid earlier mutations—for example, one Region may be
compliant before a later Region returns an unexpected service response. Do not
manually undo successful safety settings. Read the last completed postcondition,
fix the parser/permission/service issue, and rerun the same command; the wrapper
is intentionally inspect-before-mutate and idempotent.

## GuardDuty single-Region policy

This home setup deliberately avoids cross-Region aggregation and multiple notification paths:

- Management: one detector in `us-east-1`.
- Test and Prod: one detector in `eu-central-1` per account.
- No GuardDuty deployment merely because a Region appears in an SCP allowlist.
- If workloads are later placed in another Region, either move/expand GuardDuty deliberately or accept the regional visibility gap.

GuardDuty is foundational-only: its detector is enabled with a `SIX_HOURS` publishing frequency, while S3 data events, EBS malware protection, RDS login events, Lambda network logs, runtime monitoring, and EKS audit logs are explicitly disabled and verified.

Before deploying, `deploy-guardduty.sh` reads detector state in every `INSPECTION_REGIONS` entry. A disabled non-selected detector is reported and allowed because it cannot create new findings. An enabled non-selected detector causes a hard failure. The script never disables or deletes a detector automatically.

In the selected Region, the wrapper distinguishes these states:

1. **No named stack and no detector:** create the stack and detector.
2. **Named stack owns the detector:** update that stack (or accept an empty change set), then verify stack status, physical detector ownership, detector status/frequency, and all feature settings.
3. **A detector exists without the named stack:** fail rather than silently adopting, replacing, or deleting it.
4. **The named stack and GuardDuty inventory disagree:** fail as drift and require manual reconciliation.

## Move an existing detector to the selected Region

A GuardDuty finding has both an AWS detector **Region** and, for some finding
types, a remote IP geolocation. A country/city shown for an attacker is not
proof that the detector runs there. Check the finding's AWS Region and call
`list-detectors` in that Region.

If an enabled detector already exists outside the selected home Region, inspect
ownership before creating another:

```bash
export AWS_PROFILE=<account-profile>
export OLD_GD_REGION=<existing-detector-region>

aws guardduty list-detectors --region "$OLD_GD_REGION"
aws cloudformation describe-stacks \
  --stack-name home-guardduty \
  --region "$OLD_GD_REGION"
```

If the named stack does not exist, the detector is unmanaged by this repository.
Record its detector ID locally, review/export findings you care about, then
explicitly disable it before deploying the replacement:

```bash
DETECTOR_ID=<existing-detector-id>
aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --region "$OLD_GD_REGION"
aws guardduty update-detector \
  --detector-id "$DETECTOR_ID" \
  --no-enable \
  --region "$OLD_GD_REGION"
aws guardduty get-detector \
  --detector-id "$DETECTOR_ID" \
  --region "$OLD_GD_REGION" \
  --query Status \
  --output text
```

Require `DISABLED`. Disabling is reversible and preserves the detector's
historical state according to GuardDuty retention behavior. The deployment
wrapper allows a disabled detector in a non-selected Region but rejects an
enabled one, preventing an accidental multi-Region rollout.

If an existing CloudFormation stack owns the detector, do **not** disable it
behind CloudFormation's back. Review and update/delete the owning stack through
its normal lifecycle. Stack deletion can remove the detector and is a separate
destructive decision.

## Existing-resource limitations

- Account-level S3 BPA affects the account immediately and overrides less restrictive bucket settings. The script does not alter bucket-level BPA policies.
- Enabling EBS encryption by default affects subsequently created EBS volumes and snapshot copies; it does not encrypt existing volumes.
- EC2 account-level metadata defaults apply when launch settings inherit them; they do not rewrite existing instance metadata options. AWS can return `None`/unset for an account with no explicit default; the wrapper treats that as valid and sets only `HttpTokens=required`. A disabled or unset `HttpEndpoint` remains unchanged and is verified after mutation.
- A GuardDuty stack cannot be created while an unmanaged detector already exists in its selected account/Region.
- Single-Region GuardDuty does not monitor regional resource activity in other Regions. The reduced coverage is an explicit home-setup trade-off.

## Local validation

These checks do not contact AWS:

```bash
bash -n apply-account-baseline.sh deploy-guardduty.sh
cfn-lint cloudformation/guardduty-detector.yaml
```

## Files

```text
account-baseline/
├── README.md
├── apply-account-baseline.sh
├── deploy-guardduty.sh
└── cloudformation/
    └── guardduty-detector.yaml
```
