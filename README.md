# cloud-mgmt — a lightweight home AWS landing-zone starter

A small, cost-conscious collection of examples for bringing basic structure to
an **existing** personal AWS Organization without Control Tower or AWS Config.
These files are a starting point for review and adaptation—not production-ready
or enterprise controls, a compliance framework, or a substitute for threat
modeling and testing in your own organization.

The design separates the human identity used for management-plane work from the
identity used for workloads. It combines subtractive SCP guardrails, account
baselines, budget alerts, and an optional spend quarantine.

## Target organization and identities

The account and OU names are examples; discover and reconcile the real IDs and
names before deployment. The management account always remains directly under
the organization root and cannot be moved into an OU.

```text
Organization root
├── management account       # billing, Organizations, IAM Identity Center
├── Prod OU
│   └── production account   # small, stable workloads
└── Test OU
    └── test account         # experiments and higher spend risk
```

IAM Identity Center uses **two separate users** (or separately controlled
principals), with no IDs or email addresses stored in this repository:

| Principal | Assignment targets | Permission sets |
|---|---|---|
| Management principal | Management account only | `ManagementReadOnly`, `LandingZoneAdmin`, `IdentityCenterAdmin` |
| Workload principal | Management billing only | `BillingReadOnly` |
| Workload principal | Test account and, only when explicitly enabled, Prod | `WorkloadAdmin` |

The management principal never receives a workload-account assignment. The
workload principal's only management-account assignment is the intentionally
narrow `BillingReadOnly`; its administrative role exists only in Test/Prod. Selecting a
more powerful permission set on one Identity Center identity is **not step-up
MFA**: Identity Center does not necessarily issue a fresh MFA challenge during
a role switch. The meaningful boundary here is that management and workloads
use separate users with separate authentication sessions. Protect both with
strong MFA/passkeys; keep `IdentityCenterAdmin` sessions short.

Suggested allowed Regions are `us-east-1`, `us-west-2`, `eu-central-1`,
`eu-north-1`, and `ap-southeast-1`, plus required global services. SCPs do not
apply to the management account, so management access is the recovery path for
member-account policy mistakes.

## Components

| Folder | Purpose | Mechanism | Deployment target |
|---|---|---|---|
| [`idc-permission-sets`](./idc-permission-sets) | Separate management/workload users with management roles, billing visibility, and workload administration | Console-only temporary bootstrap, then CloudFormation (`AWS::SSO::*`) through SSO | Management account, Identity Center home Region |
| [`account-baseline`](./account-baseline) | Enable S3 account Block Public Access, EBS default encryption, IMDSv2 defaults, and optional GuardDuty | CLI + CloudFormation | Each account |
| [`scp-guardrails`](./scp-guardrails) | Region, service, instance-size, baseline-security, and cost guardrails | CloudFormation (`AWS::Organizations::Policy`) | Management account |
| [`budget-alarms`](./budget-alarms) | One managed $20 organization-wide Safety Net | CloudFormation (`AWS::Budgets::Budget`) | Management account |
| [`cost-quarantine`](./cost-quarantine) | Automatic SCP containment at Test forecasted $50 and Prod actual $50; optional remediation disabled | Native Budgets actions + Organizations SCP | Management account by default |
| [`scheduled-switch`](./scheduled-switch) | Turn selected expensive resources off while idle | SAM / Lambda | Workload accounts |

Review every component README and template before use. Account IDs, OU IDs,
principal IDs, email addresses, and profile names are deployment inputs and must
not be committed.

## Safety prerequisites

1. An existing AWS Organization with all features and SCP policy type enabled.
   Keep the AWS-managed `FullAWSAccess` SCP attached; custom SCPs subtract from
   it.
2. IAM Identity Center enabled, with distinct management and workload users and
   its home Region known.
3. Root users protected with MFA. **Do not create root access keys.** Do not use
   root for this deployment. Prefer centralized root access for member accounts
   where available.
4. One existing, tightly monitored, MFA-protected **console-only** IAM
   break-glass user in the management account. It must have zero access keys and
   is used only to create one temporary Identity Center assignment—not for CLI
   or CloudFormation.
5. AWS CLI v2 and local validation tools (`cfn-lint`; `shellcheck` recommended).
6. Named AWS CLI SSO profiles. Every CLI mutation and every CloudFormation
   deployment in this repository uses `aws sso login`; raw or long-lived IAM
   credentials are never part of the workflow.

## Getting started: bootstrap Identity Center first

This is the only bootstrap path supported by this repository. It requires no IAM
access key.

### 1. Create one temporary assignment in the AWS console

Sign in to the management account console as the break-glass IAM user and
complete MFA. In the IAM Identity Center home Region:

1. Create a custom permission set named `TemporaryBootstrapAdministrator`.
2. Attach the AWS-managed `AdministratorAccess` policy.
3. Set its session duration to one hour.
4. Assign it to the **management IdC user** for the management account only.
5. Copy the access-portal URL, IdC Region, and temporary permission-set ARN to a
   local record outside Git.

Do not use root, create an IAM access key, or deploy a stack from the IAM user.
If the temporary name already exists, stop and reconcile its assignments first.

### 2. Configure the local SSO profile

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
aws configure sso --profile home-mgmt-bootstrap
aws sso login --profile home-mgmt-bootstrap
AWS_PROFILE=home-mgmt-bootstrap aws sts get-caller-identity
```

In `aws configure sso`, name the SSO session `home-mgmt`, use the portal URL
and IdC Region from the console, then select the management account and
`TemporaryBootstrapAdministrator`. Verify the STS account is management and the
ARN contains `AWSReservedSSO_TemporaryBootstrapAdministrator_`.

After permanent access is deployed, keep one local SSO session per IdC user and
one profile per account/role combination:

```text
home-mgmt session:     home-mgmt-readonly, home-mgmt-landing, home-mgmt-identity
home-workload session: home-billing-readonly, home-test-admin, home-prod-admin (when assigned)
```

Profiles sharing a session also share one user login, but management and
workload profiles must never share a session. The complete `~/.aws/config`
example, browser-session precautions for selecting the correct user, and profile
verification commands are in
[`idc-permission-sets/README.md`](./idc-permission-sets/README.md#step-5--configure-local-sessions-and-permanent-profiles).

The AWS CLI now obtains and refreshes short-lived role credentials from its SSO
cache. To authorize a local automation agent, provide only the profile name and
the operation it may perform—never paste credentials or cache contents.

### 3. Inventory, deploy permanent access, and retire bootstrap

Use `home-mgmt-bootstrap` for the read-only inventory below before creating any
stack. Then follow [`idc-permission-sets`](./idc-permission-sets):

1. Discover the IdC instance ARN, identity-store ID, and the two distinct user
   IDs through the temporary SSO profile.
2. Run `idc-permission-sets/deploy.sh` through that profile to create permanent
   `ManagementReadOnly`, `LandingZoneAdmin`, `IdentityCenterAdmin`,
   `BillingReadOnly`, and `WorkloadAdmin` assignments.
3. Configure and verify every permanent SSO profile independently.
4. Run `retire-bootstrap.sh`; it removes the temporary assignment only after
   all expected permanent profiles and assignments pass verification.
5. Confirm in IAM that the break-glass user still has zero access keys.

## Reconcile an existing organization first (read-only)

Do not assume the example shape matches reality. If permanent management SSO
already exists, use `ManagementReadOnly`; during first bootstrap, use
`home-mgmt-bootstrap`. Run this inventory **before any CloudFormation
deployment**:

```bash
export AWS_PROFILE=<management-read-only-profile>
export AWS_REGION=<identity-center-home-region>

aws sts get-caller-identity
aws organizations describe-organization
aws organizations list-accounts
aws organizations list-roots
aws organizations list-organizational-units-for-parent --parent-id <root-id>
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
aws organizations list-policies-for-target \
  --target-id <root-ou-or-account-id> --filter SERVICE_CONTROL_POLICY
aws sso-admin list-instances --region "$AWS_REGION"
aws cloudtrail describe-trails --include-shadow-trails --region <region>
```

Repeat relevant account/Region checks with each account's read-only or workload
profile. Record the intended mapping of management, Test, and optional Prod IDs
in a **local ignored audit output**, compare it with deployed stacks and policy
attachments, and resolve drift or naming collisions before creating resources.
Never commit account IDs, principal IDs, emails, CLI cache files, or inventory
output.

## Deployment sequence

Order matters, particularly around Identity Center bootstrap and S3 Block
Public Access.

1. **Create temporary access in the console.** Sign in to the management
   account as the MFA-protected console-only break-glass IAM user, create the
   one-hour `TemporaryBootstrapAdministrator` permission set, and assign it only
   to the management IdC user in the management account. Do not create an access
   key or deploy CloudFormation.
2. **Switch permanently to SSO for CLI work.** Configure
   `home-mgmt-bootstrap`, run `aws sso login`, unset ambient credential
   variables, and verify the management account and temporary SSO role with STS.
3. **Reconcile through SSO.** Use the temporary profile to perform the complete
   read-only organization/IdC/policy inventory above. Resolve identity-stack
   name collisions before proceeding.
4. **Deploy permanent access through SSO.** Run
   `idc-permission-sets/deploy.sh`; it rejects non-SSO callers and checks the
   management account, organization, instance, accounts, and distinct users.
5. **Verify and retire temporary access.** Configure and sign in to permanent
   profiles for all assigned roles. After replacement profiles work, remove the
   legacy group-derived broad Billing assignment in management and the
   overlapping Administrator/ViewOnly assignments in Test/Prod. Run
   `retire-bootstrap.sh`, which verifies permanent profiles, allows only
   `BillingReadOnly` for the workload user in management, and confirms that the
   temporary permission set is provisioned only to management before deleting
   it through `IdentityCenterAdmin`. Keep the IAM break-glass principal disabled
   or otherwise controlled according to your recovery procedure; do not delete
   an untested recovery path casually.
6. **Apply account baselines in every account.** Do this before attaching the
   baseline-security SCP: that policy denies `s3:PutAccountPublicAccessBlock`, so S3 account Block
   Public Access must already be enabled. Use `LandingZoneAdmin` for management
   and `WorkloadAdmin` for Test/Prod.
7. **Deploy and attach SCP guardrails.** Use `LandingZoneAdmin`. Start with
   narrow targets, test in Test, and move policies to the intended OUs only after
   reconciliation. Keep management at the organization root and remember SCPs
   do not constrain it.
8. **Deploy the managed Safety Net.** Use `LandingZoneAdmin` to create the new
   $20 organization-wide budget. Verify its subscriber and four notifications,
   then separately delete the legacy unmanaged `Safety Net` only with explicit
   authorization.
9. **Deploy SCP-only cost quarantine after compatibility review.** The default
   creates Test forecasted-$50 and Prod actual-$50 automatic Budget actions that
   attach the generic containment SCP. Release is manual. Keep
   `ENABLE_REMEDIATION=false`; no Test role, SNS, Lambda, or Step Functions
   resources are deployed.
10. **Optionally deploy scheduled switching** from the appropriate workload SSO
   profile.

Every CloudFormation deployment in this workflow uses an SSO profile. The IAM
break-glass principal is never used to run CloudFormation.

## CloudTrail decision

This starter intentionally configures **no organization trail**. The accepted
default is CloudTrail **Event History**: free access to the last 90 days of
management events in each account and Region. This is adequate for lightweight,
short-window troubleshooting, but its limitations are accepted explicitly:
there is no organization-wide aggregation, no retention beyond 90 days, no
data events, no Insights events, and no independently protected central archive.
Event History must be searched separately in each account/Region. Add a secured
organization trail or CloudTrail Lake only when the retention, investigation,
and cost requirements justify it; reconcile existing trails first to avoid
surprise duplicate delivery and charges.

## Security boundaries and residual risk

- `LandingZoneAdmin` can manage approved Organizations, Budgets, baseline, and
  CloudFormation operations. Its IAM lifecycle and `PassRole` permissions are
  limited to four fixed cost-quarantine roles whose normal lifecycle uses the
  boundary created by the identity stack; it cannot pass a role to
  CloudFormation.
- `IdentityCenterAdmin` is inherently an escalation-capable role: it can change
  permission sets and assignments. A short session and deliberate use reduce
  exposure, but switching to it on the same management identity is not a new MFA
  factor.
- `BillingReadOnly` uses AWS `AWSBillingReadOnlyAccess` in management for the
  workload user; it replaces the broader legacy `job-function/Billing` group
  assignment.
- `WorkloadAdmin` uses AWS `AdministratorAccess` in assigned workload accounts.
  Separate users prevent accidental administrative crossover, not compromise of
  either user.
- Budget evaluation and quarantine lag cost ingestion and are damage limiters,
  not hard real-time spend caps.
- Service-specific credentials may not share the same enforcement properties as
  ordinary IAM sessions. Avoid long-lived credentials and rely on cost alerts as
  a backstop.

This repository deliberately favors a small, understandable design. Treat every
policy as reviewable source, test failure and recovery paths, and adapt it to the
actual organization rather than treating the examples as guarantees.
