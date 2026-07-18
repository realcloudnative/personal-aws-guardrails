# cloud-mgmt — a lightweight home AWS landing-zone starter

A small, cost-conscious collection of examples for bringing basic structure to
an **existing** personal AWS Organization without Control Tower or AWS Config.
These files are a starting point for review and adaptation—not production-ready
or enterprise controls, a compliance framework, or a substitute for threat
modeling and testing in your own organization.

The design separates the human identity used for management-plane work from the
identity used for workloads. It combines subtractive SCP guardrails, account
baselines, budget alerts, and an optional spend quarantine.

## Design philosophy: guardrails for the agentic age

This is not a traditional landing zone. It is purpose-built for a home AWS setup
where AI coding assistants routinely create and modify infrastructure. The core
assumption: **prevention is cheaper than remediation**.

AI agents make assumptions that fit enterprise purposes but not home budgets. A
coding assistant asked to "make this production-ready" will add a NAT Gateway, an
Application Load Balancer, and an RDS instance — all reasonable in a business
context, all costing $50–200/month idle in a personal one. One missing prompt,
one trusting "yes", and it's deployed. Budget alarms fire hours later.

The damage is not always dramatic. Agents also create KMS customer-managed keys
($1/month each, forever), allocate Elastic IPs ($3.60/month since February 2024),
provision CloudWatch dashboards ($3/month), and enable "best-practice" features
that have recurring charges. Individually negligible in an enterprise; in a home
setup targeting a $20/month total, five unnecessary resources can double the bill.
Prevention at the organization level is the only defense that works against both
catastrophic mistakes and death by a thousand cuts.

The layered defense model:

1. **SCPs (hardest boundary):** Organization-level service and resource denials
   that no IAM policy, no agent, and no human in a workload account can override.
   If a resource type costs meaningful money just *existing* and isn't needed,
   its creation is denied at the organization level.
2. **Budget actions (automatic containment):** When spend thresholds are breached,
   an SCP immediately blocks further resource creation and a state machine stops
   what's already running.
3. **Remediation (damage control):** Multi-region Step Functions that scale ECS
   services to zero, ASG groups to zero, and stop standalone EC2 instances.
4. **Identity separation:** Management and workload use different users, different
   sessions, different permission boundaries.

This order is deliberate: prevention → containment → remediation → isolation.
Each layer catches what the previous one missed. The goal is to prefer brief
downtime over runaway bills — this is a home setup paid from a personal account.

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
| [`scp-guardrails`](./scp-guardrails) | Layered SCPs: org-root baseline (security, regions, service allowlist, cost commitments) + OU-level cost guards (networking, compute, storage/DB, instance size) | CloudFormation (`AWS::Organizations::Policy`) | Management account |
| [`budget-alarms`](./budget-alarms) | One managed $20 organization-wide Safety Net | CloudFormation (`AWS::Budgets::Budget`) | Management account |
| [`cost-quarantine`](./cost-quarantine) | Automatic SCP containment at Test forecasted $50 and Prod actual $50; optional multi-region resource remediation (zero Lambda) | Native Budgets actions + Organizations SCP + StackSets + Step Functions | Management account + workload accounts |
| [`scheduled-switch`](./scheduled-switch) | Turn selected expensive resources off while idle | SAM / Lambda | Workload accounts |

Review every component README and template before use. Account IDs, OU IDs,
principal IDs, email addresses, and profile names are deployment inputs and must
not be committed.

## Choose your starting point

This repository is designed for adoption, not only for a blank setup. Start at
the first row that matches reality; do not recreate access or controls merely to
make the environment resemble an example.

| Current state | Start here | Do not do yet |
|---|---|---|
| IdC is enabled, but no management CLI role exists | Create the console-only temporary assignment below | Do not create IAM access keys |
| `TemporaryBootstrapAdministrator` already works | Run the read-only inventory, then deploy permanent IdC access | Do not attach SCPs or remove bootstrap |
| Permanent management SSO already works | Use `ManagementReadOnly` for inventory and reconcile existing assignments | Do not create a second temporary administrator |
| Baselines, SCPs, budgets, or GuardDuty already exist | Use each component's adoption/replacement path | Do not overwrite, adopt, detach, disable, or delete by name alone |
| These exact CloudFormation stacks already exist | Inspect stack status, parameters, outputs, drift, and live service state before updating | Do not assume source and deployed state still match |

There is intentionally no one-shot installer. Identity, baseline mutation, SCP
creation, SCP attachment, budget replacement, and quarantine are separate
operations with separate rollback points.

## Manual and assisted operation

A human remains responsible for authentication and approval. A local automation
assistant can reduce transcription errors and perform verification safely when
given only:

- an SSO profile name;
- the exact allowed operation (for example, “read-only inventory” or “deploy the
  detached SCP stack”); and
- explicit approval immediately before security-sensitive mutations or deletion.

Never send an assistant access keys, SSO tokens, browser cookies, cache files, or
raw credentials. Prefer this operating loop for both manual and assisted use:

1. **Identify** the account, Region, caller ARN, existing owner, and intended
   resource name.
2. **Inspect** current service state with read-only APIs.
3. **Preview** what will be created, updated, attached, disabled, or deleted.
4. **Mutate one boundary at a time.** Stack creation and policy attachment are
   deliberately different steps.
5. **Verify through the service API**, not only a successful shell exit or
   CloudFormation status.
6. **Stop on mismatch.** Preserve partial progress, fix the assumption or
   parser issue, and rerun the idempotent wrapper instead of improvising.

Keep a local ignored record of discovered identifiers and decisions. Public
issues, commits, examples, and logs must use placeholders.

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

## Operational rollout and checkpoints

Order matters, particularly around Identity Center bootstrap and S3 Block Public
Access. Treat each numbered item as a resumable phase; record its postconditions
before moving on.

1. **Establish one temporary management SSO path when needed.** Create the
   console-only assignment, configure `home-mgmt-bootstrap`, unset ambient IAM
   credentials, and verify the management account and exact temporary role with
   STS. If permanent management SSO already works, skip temporary creation.
   **Stop** if the assignment exists with unexpected principals/accounts or the
   caller does not match management.
2. **Inventory before creating.** Reconcile accounts, OUs, IdC users and
   assignments, SCP contents/targets, active stack names, budgets, GuardDuty
   detectors, and CloudTrail trails. **Continue only when** intended IDs and
   ownership are recorded locally and naming collisions are understood.
3. **Deploy permanent identity access.** Run
   `idc-permission-sets/deploy.sh` through temporary bootstrap on first creation
   or `IdentityCenterAdmin` on updates. **Continue only when** the stack is
   healthy and every permission set has the expected managed/inline policies
   and direct assignment.
4. **Configure two local SSO sessions, not one wizard per profile.** Reuse
   `home-mgmt` for all management profiles and `home-workload` for Billing/Test/
   Prod profiles. Authenticate once per IdC user and verify every STS account and
   role. Remove overlapping legacy assignments only after replacement profiles
   work; then run `retire-bootstrap.sh`.
5. **Apply baselines account by account.** Run management through
   `LandingZoneAdmin` and member accounts through `WorkloadAdmin`. The wrapper
   may make valid partial progress before an error; fix the cause and rerun it
   idempotently. **Do not attach baseline security** until all four S3 account
   Block Public Access settings are verified in that member account.
6. **Create SCPs detached.** Run `scp-guardrails/deploy.sh` with no targets.
   A healthy stack and six policies with zero targets changes no effective
   workload permissions. Static `cfn-lint` is not the AWS parser; a change-set
   rejection should produce no resources, and the template must be fixed and
   validated rather than bypassed.
7. **Attach SCPs incrementally.** Start in Test, one policy at a time. After
   each attachment, exercise normal read/deploy/update/stop/delete and recovery
   paths through the workload profile. For Prod, attach and prove a replacement
   before detaching its legacy equivalent; overlapping denies intersect. Keep
   management outside workload OUs as the recovery path.
8. **Replace budgets without an alert gap.** Create the managed $20 Safety Net,
   verify its live limit, notifications, and subscriber, allow temporary
   coexistence, then delete the old unmanaged budget as a separate authorized
   operation.
9. **Choose GuardDuty scope deliberately.** This home default uses one detector
   per account, not every SCP-allowed Region. Inspect ownership first; disable
   rather than silently delete an unmanaged detector, then deploy and verify the
   selected Region. A finding's detector Region is different from the remote
   IP's geographic location.
10. **Deploy quarantine only after workload compatibility review.** The default
    creates automatic Test forecasted-$50 and Prod actual-$50 SCP actions with
    manual release. Start with `ENABLE_REMEDIATION=false`. When ready for
    active remediation: deploy the service-managed StackSet (cross-account role
    to both OUs with auto-deployment), the self-managed StackSet (regional state
    machines in all 5 Regions in the management account), and enable the
    EventBridge forwarding rule. Verify with `test-remediation.sh` before
    relying on automatic triggers. No Lambda functions are created in any mode.
11. **Optionally deploy scheduled switching** from the appropriate workload SSO
    profile after its independent review.

Management-only phases can be paused ahead of workload login: permanent identity
creation, the management baseline, detached SCP creation, the managed budget,
and management GuardDuty can be completed and verified independently. Do not
retire bootstrap, remove legacy workload access, mutate member baselines, attach
workload SCPs, or arm quarantine until the relevant workload profiles have been
tested.

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
