# Organization Policies

Non-SCP organization policies that complement the service control policies in `scp-guardrails/`.
These policy types operate at different enforcement levels and fill gaps SCPs cannot cover.

## Why these exist alongside SCPs

| Gap | Solution |
|-----|----------|
| SCPs don't survive new APIs (a new launch path could bypass your deny) | Declarative EC2/S3 policies enforce at the service control plane |
| SCPs can't stop external principals accessing your resources via resource policies | Resource Control Policies (RCPs) create a data perimeter |
| AI content training opt-out is a separate mechanism from IAM | AI Services Opt-Out policy |

## Policies

### Must: Declarative EC2 (`paws-declarative-ec2`)

Enforced directly by EC2, not through IAM evaluation. Immune to new APIs.

| Control | Setting | Effect |
|---------|---------|--------|
| IMDSv2 | `http_tokens: required` | All new instances require IMDSv2 |
| Hop limit | `2` | Allows containerized workloads to reach IMDS |
| Metadata endpoint | `enabled` | IMDS available (but only v2) |
| Instance metadata tags | `enabled` | Tags accessible from within instances |
| Serial console | `disabled` | Blocks EC2 serial console access |
| Public AMI sharing | `block_new_sharing` | Prevents accidentally sharing AMIs publicly |
| Public snapshot sharing | `block_all_sharing` | Blocks all public EBS snapshot sharing |

Not included: VPC Block Public Access (blocks all internet via IGW, too restrictive for general use) and Allowed Images (useful but needs tuning per-account).

### Must: AI Services Opt-Out (`paws-ai-opt-out`)

Opts out of ALL AWS AI services using your content to improve their models. Applies to current and future AI services. Locked: no child policy can override.

Affected services include (non-exhaustive): CodeWhisperer, Comprehend, Lex, Polly, Rekognition, Textract, Transcribe, Translate, and any future AI service.

### Should: Declarative S3 (`paws-declarative-s3`)

Enforces S3 Block Public Access (all four settings) at the service level for every account. This is stronger than the SCP approach because:
- It prevents account-level modifications while active
- It survives new S3 APIs that might expose buckets
- Original account settings are preserved and restored on policy detachment

### Should: Resource Control Policy (`paws-data-perimeter`)

Creates an identity perimeter: resources in your accounts can only be accessed by principals within your organization or by AWS services acting on your behalf.

Protects against: an attacker with their own AWS credentials accessing your S3 buckets, KMS keys, SQS queues, or secrets through overly-permissive resource policies.

| Condition | Purpose |
|-----------|---------|
| `aws:PrincipalOrgID` | Only your org's principals can access resources |
| `aws:PrincipalIsAWSService: false` | Exempts AWS service principals (S3 replication, CloudTrail, etc.) |

Supported services: S3, KMS, SQS, Secrets Manager, STS.

## Prerequisites

Before first deployment, all four policy types must be enabled on the organization root. The deploy script does this automatically (idempotent).

## Deploy

```bash
AWS_PROFILE=paws-mgmt-landing ./deploy.sh \
  --org-root-id r-k42v \
  --org-id o-XXXXXXXXXX
```

## Relationship to other components

```
scp-guardrails/     SCPs: limit what YOUR principals can do (allowlist + denies)
org-policies/       This: declarative config + limit what ANYONE can do to your resources
account-baseline/   Per-account settings (GuardDuty, etc.)
```

The declarative S3 policy supersedes the per-account S3 BPA setting in `account-baseline/`. Once deployed, account-level changes to Block Public Access are prevented by the org policy.
