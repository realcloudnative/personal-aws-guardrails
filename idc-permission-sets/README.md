# IAM Identity Center permission sets

This component creates permanent access for two separate IAM Identity Center
users: one management-plane user and one workload user. Account IDs, user IDs,
profile names, access-portal URLs, and email addresses are runtime inputs and
must not be committed.

## Access model

| Principal | Permission set | Target | Implementation |
|---|---|---|---|
| Management user | `ManagementReadOnly` | Management only | AWS `ReadOnlyAccess` |
| Management user | `LandingZoneAdmin` | Management only | Repository-specific control-plane policy |
| Management user | `IdentityCenterAdmin` | Management only | AWS `AWSSSOMasterAccountAdministrator` plus stack-lifecycle permissions |
| Workload user | `BillingReadOnly` | Management billing only | AWS `AWSBillingReadOnlyAccess` |
| Workload user | `WorkloadAdmin` | Test | AWS `AdministratorAccess`, bounded by SCPs |
| Workload user | `WorkloadAdmin` | Prod, optional | AWS `AdministratorAccess`, bounded by SCPs |

`AWSSSOMasterAccountAdministrator` is intentionally used for the rare identity
role instead of reproducing most of AWS's IdC administrator policy. It is broad:
it can manage permission sets, assignments, the Identity Center directory,
delegated administration, and related service/KMS integration, and AWS can add
permissions to it over time. Anyone using `IdentityCenterAdmin` can grant
administrative access, including to themselves.

`LandingZoneAdmin` remains custom because no AWS-managed policy closely matches
the required Organizations, Budgets, baseline, and bounded quarantine-role
lifecycle. It can create and pass only four fixed management quarantine roles;
it cannot pass a role to CloudFormation.

The management and workload users are the meaningful separation. The management
user receives no workload-account assignments. The workload user's only
management-account assignment is `BillingReadOnly`; it cannot administer the
management account. Selecting `LandingZoneAdmin` versus `IdentityCenterAdmin`
on the same management user is not step-up MFA and may not cause another
authentication challenge. Protect both users with strong MFA/passkeys and
separate sign-in sessions.

## Bootstrap invariant: no IAM access keys

The bootstrap IAM user is **console-only**. This runbook never creates an IAM
access key, never exports IAM-user credentials, and never uses the IAM user for
CloudFormation. The only use of that user is one MFA-authenticated console
session that creates a temporary Identity Center assignment.

All CLI and CloudFormation work starts only after `aws sso login`. Do not paste
SSO tokens or generated role credentials into a terminal, repository, issue, or
chat. The AWS CLI stores and refreshes the SSO session in its local cache.

## Step 1 — Create temporary management access in the console

1. Sign in to the **management account AWS console** as the existing break-glass
   IAM user and complete MFA. Do not use root.
2. Select the IAM Identity Center home Region.
3. Open **IAM Identity Center → Permission sets → Create permission set**.
4. Choose a custom permission set and set:
   - Name: `TemporaryBootstrapAdministrator`
   - AWS managed policy: `AdministratorAccess`
   - Session duration: `1 hour`
5. Open **AWS accounts**, select the management account, and choose **Assign
   users or groups**.
6. Select the management IdC user and assign only
   `TemporaryBootstrapAdministrator`.
7. Record locally—not in Git—the Identity Center Region, access-portal URL,
   management account ID, and temporary permission-set ARN shown by the console.

Do not create or attach anything for the workload user in this step. If a
permission set with that temporary name already exists, stop and reconcile its
assignments before reusing or deleting it.

## Step 2 — Configure and verify the temporary SSO profile locally

First ensure no unrelated credentials can override the selected SSO profile:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
aws configure sso --profile home-mgmt-bootstrap
```

Use the access-portal URL and IdC home Region from the console. Select the
management account and `TemporaryBootstrapAdministrator`, then sign in:

```bash
aws sso login --profile home-mgmt-bootstrap
AWS_PROFILE=home-mgmt-bootstrap aws sts get-caller-identity
```

Verify both facts before continuing:

- `Account` is the management account ID.
- `Arn` contains
  `assumed-role/AWSReservedSSO_TemporaryBootstrapAdministrator_`.

At this point the IAM-user console session is no longer needed. The local CLI is
using short-lived Identity Center role credentials. To let a local automation
agent use this access, provide only the profile name and the allowed operation;
do not provide tokens or credentials.

## Step 3 — Reconcile the existing organization through SSO

Perform discovery before the first CloudFormation deployment:

```bash
export AWS_PROFILE=home-mgmt-bootstrap
export REGION=<identity-center-home-region>

aws organizations describe-organization
aws organizations list-accounts
aws organizations list-roots
aws organizations list-organizational-units-for-parent --parent-id <root-id>
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
aws organizations list-policies-for-target \
  --target-id <root-or-ou-id> --filter SERVICE_CONTROL_POLICY
aws sso-admin list-instances --region "$REGION"
```

Get the instance ARN and identity-store ID from `list-instances`, then identify
the two distinct users:

```bash
aws identitystore list-users \
  --identity-store-id <identity-store-id> \
  --region "$REGION" \
  --query 'Users[].{UserName:UserName,DisplayName:DisplayName,UserId:UserId}'
```

Record the intended management, Test, and optional Prod account IDs and the two
user IDs in a local ignored file such as `.aws-audit/bootstrap.env`. Confirm
that no existing permission sets or stacks use the permanent names from this
template before deploying.

## Step 4 — Deploy permanent access through temporary SSO

```bash
export REGION=<identity-center-home-region>
export SSO_PROFILE=home-mgmt-bootstrap

./deploy.sh \
  <identity-center-instance-arn> \
  <management-account-id> \
  <test-account-id> \
  <management-user-id> \
  <workload-user-id> \
  [prod-account-id]
```

The script accepts only an SSO session for
`TemporaryBootstrapAdministrator` on first deployment or
`IdentityCenterAdmin` on updates. Before CloudFormation runs it verifies the
management account, Organization, IdC instance, active member accounts, and two
distinct users.

Optional environment overrides are `STACK_NAME`,
`MANAGEMENT_READ_ONLY_SESSION_DURATION`, `LANDING_ZONE_ADMIN_SESSION_DURATION`,
`IDENTITY_CENTER_ADMIN_SESSION_DURATION`, `BILLING_READ_ONLY_SESSION_DURATION`,
and `WORKLOAD_ADMIN_SESSION_DURATION`.

## Step 5 — Configure local sessions and permanent profiles

An AWS CLI profile selects exactly one account and permission set. Profiles that
belong to the **same IdC user** should share an `sso-session`, so one login makes
all of that user's account/role profiles usable until the session expires. The
management and workload users must use different `sso-session` names even when
they share an access-portal URL.

Use this local naming model:

```text
SSO session: home-mgmt       (management IdC user)
  home-mgmt-bootstrap  → management / TemporaryBootstrapAdministrator
  home-mgmt-readonly   → management / ManagementReadOnly
  home-mgmt-landing    → management / LandingZoneAdmin
  home-mgmt-identity   → management / IdentityCenterAdmin

SSO session: home-workload   (workload IdC user)
  home-billing-readonly → management / BillingReadOnly
  home-test-admin       → Test / WorkloadAdmin
  home-prod-admin       → Prod / WorkloadAdmin  # only if assigned
```

Do **not** run the interactive wizard once per profile. The wizard is useful for
creating the first session, but the remaining entries are deterministic local
configuration.

1. If `home-mgmt-bootstrap` already works, its `[sso-session home-mgmt]` block
   is the management session. Keep it.
2. Back up the local file before editing:

   ```bash
   cp ~/.aws/config ~/.aws/config.backup-$(date +%Y%m%d-%H%M%S)
   chmod 600 ~/.aws/config
   ```

3. Add the permanent management profile blocks below, all referencing
   `sso_session = home-mgmt`.
4. Add one distinct `[sso-session home-workload]` block using the same portal URL
   and IdC Region, then add Billing/Test/Prod profiles that reference it. Never
   put tokens or credentials in this file.
5. Run `aws configure list-profiles` and inspect the file before logging in.

If starting without any local SSO configuration, run `aws configure sso` once
for the first profile of each IdC user, then add the other account/role profiles
manually. A local automation assistant may make this edit after receiving the
profile mappings, but it must preserve a backup and must never receive or print
portal tokens/cache contents.

The resulting `~/.aws/config` should have this shape. Replace placeholders only
in your local file; never copy real account IDs or portal URLs into this
repository:

```ini
[sso-session home-mgmt]
sso_start_url = <access-portal-url>
sso_region = <identity-center-home-region>
sso_registration_scopes = sso:account:access

[profile home-mgmt-bootstrap]
sso_session = home-mgmt
sso_account_id = <management-account-id>
sso_role_name = TemporaryBootstrapAdministrator
region = us-east-1
output = json

[profile home-mgmt-readonly]
sso_session = home-mgmt
sso_account_id = <management-account-id>
sso_role_name = ManagementReadOnly
region = us-east-1
output = json

[profile home-mgmt-landing]
sso_session = home-mgmt
sso_account_id = <management-account-id>
sso_role_name = LandingZoneAdmin
region = us-east-1
output = json

[profile home-mgmt-identity]
sso_session = home-mgmt
sso_account_id = <management-account-id>
sso_role_name = IdentityCenterAdmin
region = us-east-1
output = json

[sso-session home-workload]
sso_start_url = <access-portal-url>
sso_region = <identity-center-home-region>
sso_registration_scopes = sso:account:access

[profile home-billing-readonly]
sso_session = home-workload
sso_account_id = <management-account-id>
sso_role_name = BillingReadOnly
region = us-east-1
output = json

[profile home-test-admin]
sso_session = home-workload
sso_account_id = <test-account-id>
sso_role_name = WorkloadAdmin
region = eu-central-1
output = json

[profile home-prod-admin]
sso_session = home-workload
sso_account_id = <prod-account-id>
sso_role_name = WorkloadAdmin
region = eu-central-1
output = json
```

`region` is the default for ordinary commands; it does not change the IdC home
Region in the associated `sso-session`. The profile file contains configuration,
not role credentials. Short-lived tokens remain in the AWS CLI's local SSO
cache; never commit or share `~/.aws`, cache contents, or command output carrying
credentials.

Separate `sso-session` names isolate the two local CLI token caches, but they do
not choose the browser identity. The AWS CLI cannot turn one IdC user's token
into the other user's assignments; authenticate each session as the intended
user.

One login per SSO session is sufficient. Profiles added to an already logged-in
`home-mgmt` session may work immediately; otherwise authenticate once:

```bash
# Authenticates all profiles that use home-mgmt.
aws sso login --profile home-mgmt-readonly

# Authenticate once as the distinct workload IdC user. Device-code mode makes
# it easy to open the URL in a private browser and avoid reusing the management
# user's web session. This covers Billing, Test, and Prod.
aws sso login \
  --profile home-billing-readonly \
  --use-device-code \
  --no-browser
```

If the installed AWS CLI does not support those device-code flags, sign out of
the access portal in the browser (or use a separate browser profile) and run the
ordinary `aws sso login --profile home-billing-readonly`. Always verify which
IdC user the browser shows before approving the login.

Do not use the unqualified `default` profile for this repository. Select a
profile explicitly with `AWS_PROFILE` or `--profile`, then verify every
account/role pair independently:

```bash
AWS_PROFILE=home-mgmt-readonly aws sts get-caller-identity
AWS_PROFILE=home-mgmt-landing aws sts get-caller-identity
AWS_PROFILE=home-mgmt-identity aws sts get-caller-identity
AWS_PROFILE=home-billing-readonly aws sts get-caller-identity
AWS_PROFILE=home-test-admin aws sts get-caller-identity
AWS_PROFILE=home-prod-admin aws sts get-caller-identity  # only if assigned
```

For each result, require the intended account ID and an ARN containing the
expected `AWSReservedSSO_<PermissionSet>_` role name. Do not retire bootstrap
access merely because roles appear in the portal; verify every permanent
profile first. `aws sso logout` clears all locally cached SSO sessions, so use it
when deliberately ending both users' local sessions, not when merely switching
profiles.

### Reconcile the legacy broad assignments

The existing workload user may still inherit older group assignments while the
new direct assignments are being tested. Do not remove them before the
replacement profiles work. After verification, remove these legacy group
assignments in the IdC console or with reviewed `delete-account-assignment`
calls:

- management: legacy `Billing` (AWS `job-function/Billing`);
- Test and Prod: legacy `AdministratorAccess` and `ViewOnlyAccess`.

Keep the new direct `BillingReadOnly` and `WorkloadAdmin` assignments. The
retirement script deliberately refuses to remove bootstrap while any legacy
direct or group-derived workload-user assignment remains in management; the
only permitted management assignment for that user is `BillingReadOnly`.

## Step 6 — Retire the temporary assignment

```bash
export REGION=<identity-center-home-region>
export MANAGEMENT_READ_ONLY_PROFILE=home-mgmt-readonly
export LANDING_ZONE_PROFILE=home-mgmt-landing
export IDENTITY_CENTER_PROFILE=home-mgmt-identity
export WORKLOAD_BILLING_PROFILE=home-billing-readonly
export WORKLOAD_TEST_PROFILE=home-test-admin
export WORKLOAD_PROD_PROFILE=home-prod-admin  # only if Prod was assigned

./retire-bootstrap.sh \
  <identity-center-instance-arn> \
  <management-account-id> \
  <test-account-id> \
  <management-user-id> \
  <workload-user-id> \
  <temporary-permission-set-arn> \
  [prod-account-id]
```

The script verifies every permanent profile and assignment, confirms that the
temporary permission set is provisioned only to the management account and has
only the expected user assignment, waits for asynchronous assignment deletion,
and then deletes the temporary permission set through `IdentityCenterAdmin`.
Already-issued temporary role credentials can remain valid until their configured
session expires. If reconciliation finds a duration other than the recommended
one hour, correct it or explicitly accept the temporary exposure before
continuing; in either case, retire bootstrap promptly after permanent access is
proven.

Keep the IAM user as a controlled console-only recovery path if that matches the
recovery policy, but verify in the IAM console that it has **zero access keys**.
Root must also have no access keys and must remain MFA-protected.

## Local validation

These checks require no AWS credentials:

```bash
cfn-lint cloudformation/idc-permission-sets.yaml
bash -n deploy.sh retire-bootstrap.sh
shellcheck deploy.sh retire-bootstrap.sh # optional when installed
```

## Files

```text
idc-permission-sets/
├── README.md
├── deploy.sh
├── retire-bootstrap.sh
└── cloudformation/
    └── idc-permission-sets.yaml
```
