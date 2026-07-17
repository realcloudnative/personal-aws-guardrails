# scp-guardrails

Deny-Unless Service Control Policies (SCPs) for separate **Prod** and **Test**
OUs in a small AWS Organization. CloudFormation creates six policies, but every
policy is **detached by default**. Attachments happen only when its own target
parameter is explicitly supplied.

The template never targets the organization root. The deployment wrapper accepts
OU IDs only and must run with credentials for the Organizations management
account, which remains the recovery path.

## Policy model

| SCP | Intended use | Independent target parameter |
|---|---|---|
| Prod region lock | Prod-specific allowed Regions | `ProdRegionLockTargetIds` |
| Test region lock | Test-specific allowed Regions | `TestRegionLockTargetIds` |
| Service allowlist | Common service boundary, normally both OUs | `ServiceAllowlistTargetIds` |
| EC2 instance size | Stricter environment control, normally Test | `Ec2InstanceSizeTargetIds` |
| Baseline security | Common security, normally both OUs | `BaselineSecurityTargetIds` |
| Cost control | Stricter cost controls, normally Test | `CostControlTargetIds` |

Each target parameter accepts a comma-separated list of OU IDs. Its default is
`NONE`, which omits `TargetIds` and leaves that SCP detached. No account, root,
or OU identifiers are embedded in the repository.

A typical split is:

- **Common security (Prod + Test):** baseline security and, after compatibility
  testing, the service allowlist. Supply both OU IDs to each policy's parameter.
- **Prod:** its own conservative Region list and stricter, stability-oriented
  controls validated against production recovery procedures.
- **Test:** its own explicit Region list plus EC2 size and cost controls. Add an
  experimental Region deliberately without changing Prod, then remove it only
  after its resources have been inventoried and cleaned up.

Both Region lists default independently to `us-east-1`, `us-west-2`,
`eu-central-1`, `eu-north-1`, and `ap-southeast-1`.

## What baseline security enforces

The common baseline denies:

- launches without IMDSv2 and modifications that explicitly set
  `HttpTokens=optional`; unrelated metadata-options changes are not denied;
- unencrypted EBS volume creation and disabling EBS encryption by default;
- changing or deleting account-level S3 Block Public Access;
- IAM user, access-key, and login-profile creation; and
- leaving the Organization.

Enable all four account-level S3 Block Public Access settings **before** attaching
this policy because AWS has no request condition that distinguishes enabling from
disabling them.

There is deliberately no CloudTrail lifecycle protection: this repository relies
on the default 90-day CloudTrail Event History and creates no trail to protect.
There is also no GuardDuty lifecycle deny. GuardDuty is optional in the account
baseline, and SCP lifecycle locks can prevent legitimate disablement,
administrator changes, or decommissioning.

The service allowlist includes the distinct `bedrock-mantle:*` prefix used by
Amazon Bedrock Powered by AWS Mantle. Mantle's AWS-managed inference policy also
uses `aws-marketplace:Subscribe` and `aws-marketplace:ViewSubscriptions` for
third-party models; those actions pass the allowlist, but an explicit SCP deny
still blocks `Subscribe` unless `aws:CalledViaLast` is
`bedrock-mantle.amazonaws.com`. The quarantine separately denies Mantle's
`CreateInference` and `CallWithBearerToken` spend paths.

The service allowlist still permits the `cloudtrail:*` and `guardduty:*` service
prefixes; permitting a service through an SCP grants no IAM permission by itself.

## Effective policy behavior and `FullAWSAccess`

Keep AWS's default `FullAWSAccess` SCP attached at every applicable level. These
policies contain only explicit denies: they subtract permissions and never grant
one. Removing `FullAWSAccess` can make an OU unusable when no other SCP supplies
an allow.

Effective access is the intersection of identity/resource permissions and every
SCP inherited through the organization hierarchy. An explicit deny in **any**
applicable SCP wins. For example, allowing EC2 in the service allowlist does not
override the Test Region lock, EC2 size control, or an inherited parent policy.
Before attaching common security to both OUs, test the combined effective policy,
not each document in isolation.

## Deploy safely

Prerequisites: AWS CLI v2, SCP policy type enabled, `FullAWSAccess` retained, and
credentials for the Organizations **management account**. Delegated administrator
credentials are intentionally rejected by the wrapper.

First create all six policies detached:

```bash
cd scp-guardrails
./deploy.sh
```

The script prints the current STS identity, calls Organizations to verify its
account is the management account, validates OU/Region formats, and displays the
complete attachment plan. If any target is present, it requires typing `ATTACH`.
For an intentional non-interactive run, set `ATTACH_CONFIRMATION=ATTACH`.

After reviewing the detached policy documents, attach in small stages. The IDs
below are examples of the required format, not values to copy:

```bash
./deploy.sh \
  --prod-region-targets ou-abcd-11111111 \
  --test-region-targets ou-abcd-22222222 \
  --service-allowlist-targets ou-abcd-11111111,ou-abcd-22222222 \
  --baseline-targets ou-abcd-11111111,ou-abcd-22222222 \
  --ec2-size-targets ou-abcd-22222222 \
  --cost-control-targets ou-abcd-22222222
```

Use `--prod-regions` and `--test-regions` for different lists. The wrapper sends
all target parameters on every run; omitted target options become `NONE` and are
therefore detached. This makes `./deploy.sh` a deliberate detach-all rollback,
subject to the identity and management-account checks.

Environment overrides are `STACK_NAME`, `REGION`, and `POLICY_NAME_PREFIX`.
Policy names and tags are generic (`project=cloud-mgmt`,
`component=scp-guardrails`, `managed-by=cloudformation`).

## Staged reconciliation with legacy policies

Do not replace an attached legacy Region lock in one step. Reconcile it as a
controlled migration:

1. Inventory all policies directly attached to Prod and Test and all inherited
   policies. Record the effective policy for representative accounts.
2. Deploy this stack detached. To run it beside an existing stack whose names
   would conflict, use a new `STACK_NAME` and `POLICY_NAME_PREFIX`.
3. Compare each new policy with the corresponding legacy policy. Resolve service
   and Region differences before attachment.
4. Attach one new common policy to Test, exercise normal deploy/read/update/delete
   paths, then proceed policy-by-policy. Apply the Prod Region lock only after
   Prod validation and a rollback window are ready.
5. Detach the equivalent legacy policy only after the new policy is proven. Do
   not leave overlapping old/new Region policies unintentionally: their allowed
   Regions intersect, so the narrower result wins.
6. Observe for a suitable period, then explicitly decommission retained legacy
   policies.

### Resources in Regions being removed

A Region-lock SCP does not stop or delete existing resources. It can deny the API
calls needed to inspect, modify, stop, export, or delete them. Before removing a
Region, inventory and migrate or delete its resources, including regional logs,
snapshots, keys, and networking dependencies. If something is missed, restore
the Region to the relevant allowed list from the management account, perform the
cleanup, then narrow the list again.

## Rollback and decommissioning

Fast rollback is to rerun the wrapper without the affected target option (or with
no target options to detach all managed SCPs). Because the management account is
not affected by SCPs, it can also detach a bad policy through Organizations if a
CloudFormation update cannot complete. Restore service first; investigate policy
changes second.

Every policy has `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`.
Deleting or replacing the stack therefore does not silently remove a protection.
This also means stack deletion is **not** decommissioning: retained policies can
remain attached and continue denying actions. To retire one safely:

1. remove its targets and deploy;
2. verify the OU's effective policy and workloads;
3. delete the stack if desired; and
4. explicitly delete the now-detached retained policy from Organizations.

Never delete an attached policy merely to force a CloudFormation operation.

## Local validation

No AWS access is needed for static checks:

```bash
cfn-lint cloudformation/scp-guardrails.yaml
bash -n deploy.sh
```

The template uses native YAML objects for `AWS::Organizations::Policy.Content`,
so policy conditions can directly reference CloudFormation parameters without
stringified JSON.

## Files

```text
scp-guardrails/
├── README.md
├── deploy.sh
└── cloudformation/
    └── scp-guardrails.yaml
```
