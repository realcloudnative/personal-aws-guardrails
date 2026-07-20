# scp-guardrails

Layered Service Control Policies (SCPs) for a personal AWS Organization. Two
functional layers: universally sensible guards at the org root, and one
opinionated cost guard at the OU level. All policies are deployed **detached
by default** and require explicit attachment.

See the [root README](../README.md#design-philosophy-guardrails-for-the-agentic-age)
for the high-level philosophy, tenets, and layered defense model.

## Why SCPs for a home setup

Budget alerts and cost quarantine react *after* money is spent. SCPs prevent
the spend from ever starting. This matters because:

- **AI coding assistants make enterprise assumptions.** One trusting "yes" and a
  NAT Gateway, ALB, or CMK is deployed. SCPs make that physically impossible.
- **Small charges accumulate.** $1 CMK + $3.60 EIP + $3 dashboard + $0.50 hosted
  zone = $8/mo from four "negligible" resources. That's 40% of a $20 target.
- **Prevention beats detection.** No CloudWatch alarm fires fast enough to catch
  a resource that costs money the instant it exists.
- **Credential theft targets expensive services.** SCPs deny the attack surface
  at a level no compromised IAM role can override.

## Architecture: two functional layers

```text
Organization root ─── Org-root baseline (universally sensible)
├── Prod OU ───────── Opinionated cost guard (my choices)
└── Test OU ───────── Opinionated cost guard (same policy)
```

### Layer 1: Org root — universally sensible (`scp-org-baseline.yaml`)

Four policies that apply to **all** member accounts. No reasonable home setup
would disagree with these. Fork-safe: keep them unchanged.

| Policy | What it enforces |
|---|---|
| **Baseline security** | IMDSv2, EBS encryption, no long-lived credentials, protect quarantine role |
| **Region lock** | 5 allowed regions; global services exempted |
| **Service allowlist** | Only permitted services exist; everything else is hard-denied |
| **Cost commitments** | No reserved instances, capacity blocks, dedicated hosts/tenancy |

### Layer 2: OU level — opinionated (`scp-ou-policies.yaml`)

One policy containing all "I don't want this but someone else might." Detach or
customize if you fork this repository.

| Policy | What it enforces |
|---|---|
| **Opinionated cost guard** | Instance sizes, networking, compute, storage, databases, death-by-a-thousand-cuts |

---

## Org-root: baseline security

Denies all forms of long-lived credentials and protects security invariants:

| Sid | What | Why |
|---|---|---|
| `RequireImdsv2OnLaunch` | EC2 must use IMDSv2 | Prevents SSRF credential theft |
| `DenyExplicitImdsv1OnExisting` | Cannot downgrade to IMDSv1 | Same |
| `DenyLeaveOrganization` | Cannot leave the org | Prevents policy evasion |
| `DenyDisableEbsEncryptionByDefault` | Cannot turn off default encryption | Data protection |
| `RequireEncryptedEbsVolumes` | All volumes must be encrypted | Data protection |
| `ProtectS3AccountPublicAccessBlock` | Cannot change S3 public access block | Prevents exposure |
| `DenyLongLivedCredentials` | No IAM users, access keys, SSH keys, service-specific creds, signing certs | **Only SSO sessions and service roles allowed** |
| `ProtectQuarantineRemediationRole` | Cannot modify the quarantine role | Ensures cost remediation always works |

### Long-lived credential deny (detail)

The `DenyLongLivedCredentials` statement blocks:
- `iam:CreateUser` — no IAM users in workload accounts
- `iam:CreateAccessKey` — no programmatic access keys
- `iam:CreateLoginProfile` — no console passwords
- `iam:CreateServiceSpecificCredential` — no CodeCommit HTTPS creds
- `iam:UploadSSHPublicKey` — no SSH keys for CodeCommit
- `iam:UploadSigningCertificate` — no X.509 signing certs

**IAM Roles Anywhere** (`rolesanywhere:*`) is blocked by the service allowlist
(not in the permitted list). Defense in depth: even if someone adds it to the
allowlist, the credential deny blocks the underlying IAM operations.

**What remains allowed:**
- `iam:CreateRole` — services and CloudFormation need this
- `iam:CreateServiceLinkedRole` — AWS services create these automatically
- `iam:PutRolePolicy`, `iam:AttachRolePolicy` — normal role management
- All STS operations — temporary credentials are the intended path

## Org-root: service allowlist

The most powerful policy. Uses `NotAction` + `Effect: Deny`: any service NOT
listed is completely blocked. This is the primary deny layer.

### Services allowed (by category)

| Category | Namespaces | Notes |
|---|---|---|
| AI & ML | `bedrock`, `bedrock-agentcore`, `bedrock-mantle`, `aws-external-anthropic` | Core AI stack |
| Serverless | `apigateway`, `execute-api`, `events`, `scheduler`, `pipes`, `lambda`, `states`, `sns`, `sqs` | Pay-per-use foundation |
| Compute | `ec2`, `ec2messages`, `autoscaling`, `application-autoscaling`, `ecs`, `ecr`, `ecr-public` | Size-limited by OU policy |
| Storage | `s3`, `s3files`, `dynamodb` | S3 Files is the NFS path to S3 (no EFS needed) |
| Analytics | `athena`, `glue` (catalog only) | Glue limited to Data Catalog operations |
| Networking | `cloudfront`, `route53`, `route53domains` | No ELB, no TGW, no VPN |
| Security | `acm`, `cognito-idp`, `guardduty`, `iam`, `kms`, `sso`, `sso-directory`, `sso-oauth`, `identitystore`, `sts` | KMS allowed but CreateKey denied at OU |
| Monitoring | `cloudformation`, `cloudshell`, `cloudtrail`, `cloudwatch`, `logs`, `resource-explorer-2`, `servicequotas`, `ssm`, `ssmmessages`, `tag`, `uxc` | Resource Explorer for visibility |
| Developer | `codecommit` | Returned to GA Nov 2025 |
| Billing | `account`, `artifact`, `aws-marketplace` (scoped), `aws-portal`, `bcm-data-exports`, `billing`, `budgets`, `ce`, `consolidatedbilling`, `cost-optimization-hub`, `cur`, `freetier`, `health`, `invoicing`, `organizations`, `payments`, `support`, `tax`, `trustedadvisor` | Management plane |

### Services hard-denied (by omission)

| Removed service | Monthly idle cost | Alternative |
|---|---|---|
| `elasticloadbalancing` (ALB/NLB) | $16+ | API Gateway + CloudFront |
| `dax` (DynamoDB Accelerator) | $40+ | Not needed at home scale |
| `kinesis`, `firehose`, `kinesisanalytics`, `kinesisvideo` | $11+/shard | SQS + EventBridge |
| `rds` (all actions) | $15+ | DynamoDB |
| `elasticfilesystem` (EFS) | $0.30/GB/mo | S3 Files (`s3files:*`) |
| `apprunner` | $5+ even idle | Lambda + API GW |
| `imagebuilder` | Launches instances | Pre-built AMIs |
| `mediaconvert` | Per-minute billing | ffmpeg on EC2 |
| `transcribe`, `translate` | Pay-per-use | Not needed |
| `codebuild`, `codepipeline`, `codedeploy`, `codeartifact` | $1/pipeline/mo | GitHub Actions or local |
| `cognito-identity`, `cognito-sync` | Legacy/unused | Cognito User Pools kept |
| `s3-object-lambda` | Lambda per GET | Not needed |
| `schemas` (EventBridge) | Discovery charges | Not needed |
| `cloudfront-keyvaluestore` | Not using | Not needed |
| `route53resolver` | $90/mo per endpoint | Not needed |
| `ram` | Free but unused | Not needed now |
| `supportplans` | Can upgrade tier | `support:*` kept for tickets |
| `purchase-orders` | Unnecessary | Personal account |
| `rolesanywhere` | Long-lived certs | Blocked — only SSO |
| `eks`, `emr`, `kafka`, `es`, `aoss` | $50-300+/mo | Blocked at multiple levels |

## Org-root: region lock

Single coarse boundary: deny all regional actions outside 5 regions. Global
services (IAM, STS, Route 53, CloudFront, billing, etc.) are exempted.

Default regions: `us-east-1`, `us-west-2`, `eu-central-1`, `eu-north-1`,
`ap-southeast-1`.

Future: fine-grained region policies at OU level (S3-only backup region,
AI-only innovation regions) using the new Allow+Condition SCP language.

## Org-root: cost commitments

Blocks capacity purchases and dedicated tenancy:
- Reserved instances, capacity blocks, host reservations, scheduled instances
- Dedicated Hosts
- `ec2:RunInstances` with non-default tenancy

## OU-level: opinionated cost guard

One policy, all the environment-specific boundaries. Organized by function:

### Instance sizes
- Deny `ec2:RunInstances` larger than `*.nano`, `*.micro`, `*.small`

### Expensive networking
- NAT Gateway, Transit Gateway, VPN, Client VPN, EIPs

### Expensive compute
- `kms:CreateKey` -- AWS-managed keys are free and sufficient
- `bedrock:CreateProvisionedModelThroughput` -- use on-demand
- `bedrock:CreateModelCustomizationJob` -- fine-tuning is expensive
- `lambda:PutProvisionedConcurrencyConfig` -- pay-per-use is enough

### CloudWatch dashboards (tag bypass)
- Deny `cloudwatch:PutDashboard` unless tagged `CreatedBy: manual`
- Agents won't know to add the tag; you do when intentional

To create a dashboard manually:
```bash
aws cloudwatch put-dashboard --dashboard-name my-dashboard \
  --dashboard-body file://dashboard.json \
  --tags Key=CreatedBy,Value=manual
```

### Expensive storage
- Provisioned IOPS volumes (io1/io2) -- use gp3
- `s3:PutAccelerateConfiguration` -- use CloudFront instead
- `cloudtrail:CreateTrail` -- Event History (free, 90 days) is sufficient

## Deploy

Prerequisites: AWS CLI v2, LandingZoneAdmin SSO profile, management account.

Deploy detached (review policies before attaching):
```bash
cd scp-guardrails
./deploy.sh
```

Deploy attached:
```bash
./deploy.sh \
  --org-root-id r-a1b2 \
  --opinionated-targets ou-abcd-11111111,ou-abcd-22222222
```

The script verifies caller identity, validates all inputs, shows the attachment
plan, and requires typing ATTACH for confirmation. Running with no target
arguments detaches all policies (fast rollback).

## Rollback

Rerun `./deploy.sh` with no target arguments. The management account is exempt
from SCPs and can always detach directly via Organizations if CloudFormation
cannot complete.

All policies have `DeletionPolicy: Retain`. Deleting the stack does not remove
protections. To fully decommission: remove targets → verify → delete stack →
delete retained policies from Organizations.

## SCP language capabilities (since Sept 2025)

SCPs now support full IAM policy language:
- `NotResource` in Deny (restrict Bedrock to specific models)
- Wildcards mid-string in Actions (`"ec2:*NatGateway*"`)
- `Allow` with Conditions (fine-grained region-per-service policies)
- 10 policies per target, 10,240 characters per policy (since May 2026)

## Files

```text
scp-guardrails/
├── README.md
├── deploy.sh
└── cloudformation/
    ├── scp-org-baseline.yaml            # Org root: security, regions, allowlist, commitments
    ├── scp-ou-policies.yaml             # OU level: opinionated cost guard
    └── scp-regional-restrictions.yaml   # OU level: per-region specialization + Object Lock
```

## OU-level: regional specialization

Each allowed region has a defined purpose. These SCPs enforce that purpose by
denying everything except what the region is for.

| Region | Policy name | Purpose | Allowed |
|--------|-------------|---------|---------|
| us-east-1 | `paws-region-useast1-globals-only` | Global-service necessities | ACM, CloudFront, WAF, S3, Shield, SNS, CloudWatch read, KMS decrypt |
| ap-southeast-1 | `paws-region-apse1-cleanup-only` | Departing region (ex-Singapore sandbox) | List/Describe/Get + Delete/Terminate/Stop. No create, no invoke. |
| us-west-2 | `paws-region-uswest2-bedrock-only` | Model availability (Stability AI Ultra, latest LLMs) | Bedrock, Mantle, minimal S3 for artifacts |
| eu-north-1 | `paws-region-eunorth1-backup-bedrock` | Cross-region S3 backup + Bedrock | S3, KMS (replication), Bedrock, Mantle |
| eu-central-1 | _(no restriction)_ | Primary working region | Full access within allowlist |

Design: each policy uses a single `NotAction` deny with
`Condition: { StringEquals: { aws:RequestedRegion: <region> } }`. This means
everything not in the exception list is denied for that region only.

## OU-level: S3 Object Lock protection

Denies `s3:BypassGovernanceRetention` across all regions.

This makes governance-mode Object Lock unbreakable from member accounts. The
benefit over compliance mode: if you need to remove the lock (shutting down an
account, correcting a mistake), detach the SCP from the management account and
bypass is possible again. Compliance mode is truly irreversible.

Use governance mode + this SCP for important data (state files, backups, audit
logs). You get the protection of compliance mode with an org-level escape hatch.

## Future work

- Bedrock model restriction via `NotResource` (limit to specific model ARNs)
- Lambda runaway mitigation (account-level concurrency limits)
- Mid-string wildcards for future-proof denies
- CloudFront risk mitigation
