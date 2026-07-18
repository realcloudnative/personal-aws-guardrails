# scp-guardrails

Layered Service Control Policies (SCPs) for a personal AWS Organization. The
design separates universal invariants (org root) from environment-specific cost
prevention (OU-level), using two CloudFormation stacks. All policies are deployed
**detached by default** and require explicit attachment.

## Philosophy: prevention over remediation

Budget alerts and cost quarantine react *after* money is spent. SCPs prevent
the spend from ever starting. This matters in a home setup where:

- **AI coding assistants make assumptions.** An agent optimizing for "production
  readiness" will add a NAT Gateway, provision an ALB, or create an RDS instance
  without thinking about whether a personal project needs $50+/month of always-on
  infrastructure. One missing prompt, one trusting approval, and it's deployed.
- **Accidental infinite loops exist.** EventBridge → Lambda → EventBridge cycles,
  Step Functions retries, or recursive invocations can generate surprise bills
  before CloudWatch alarms fire.
- **Stolen credentials target expensive services.** Crypto miners want large
  instances; data exfiltration uses NAT Gateways and endpoints. SCPs hard-deny
  the attack surface.
- **Idle resources accumulate.** A test ALB, a forgotten NAT Gateway, or a
  "temporary" RDS instance quietly charges $30–$200/month indefinitely.

The principle: if a resource type costs meaningful money just *existing*, and
isn't needed for this setup's purpose, deny its creation at the organization
level. No IAM policy, no human approval, no agent decision can override an SCP
deny. This is the hardest possible guardrail short of not having an AWS account.

## Architecture: two layers, two stacks

### Layer 1: Org-root baseline (`scp-org-baseline.yaml`)

Attached to the organization root. Applies to **all** member accounts regardless
of OU. These are universal invariants that never need per-environment variation:

| Policy | Purpose |
|---|---|
| **Baseline security** | IMDSv2, EBS encryption, no IAM users/keys, no leave-org, protect quarantine role, protect S3 public access block |
| **Region lock** | Single coarse boundary: 5 allowed regions. Fine-grained region policies live at OU level (future) |
| **Service allowlist** | Only permit services we actually use. Everything else is hard-denied via `NotAction` |
| **Cost commitments** | No reserved instances, capacity blocks, dedicated hosts, or dedicated tenancy |

The service allowlist is the most powerful policy: any AWS service not explicitly
listed is completely blocked. This is a *subtractive* allowlist — it uses
`NotAction` (services we allow) with `Effect: Deny`, meaning anything **not** in
the list is denied. Adding a new service requires updating this policy.

**Services explicitly removed from the allowlist** (hard-denied by omission):

| Service | Monthly cost if idle | Why denied |
|---|---|---|
| `elasticloadbalancing` (ALB/NLB) | $16+ | Use API Gateway + CloudFront instead |
| `dax` (DynamoDB Accelerator) | $40+ | Unnecessary for home workloads |
| `kinesis`, `firehose`, `kinesisanalytics`, `kinesisvideo` | $11+/shard | Per-shard hourly billing, dangerous at scale |
| `rds` (all actions) | $15+ | Use DynamoDB or external databases |

### Layer 2: OU-level policies (`scp-ou-policies.yaml`)

Attached per OU. These deny **specific expensive resources within allowed
services** — defense-in-depth where the allowlist provides the first barrier:

| Policy | What it denies | Cost it prevents |
|---|---|---|
| **EC2 instance size** | Instances larger than nano/micro/small | Large instances: $50–$500+/mo |
| **Networking cost guard** | NAT GW, ALB/NLB, TGW, Lattice, Network Firewall, Global Accelerator, VPN, interface VPC endpoints | $30–$350/mo per resource |
| **Compute cost guard** | EKS, DAX, EMR, Batch, MSK, OpenSearch/AOSS | $50–$300/mo minimum |
| **Storage & DB cost guard** | Provisioned IOPS, FSx, Storage Gateway, all RDS, ElastiCache, Redshift, Neptune, MemoryDB | $13–$200/mo per resource |

**Defense-in-depth principle:** Some resources (ALB, DAX, RDS) are both removed
from the org-level allowlist *and* explicitly denied at OU level. This protects
against accidental allowlist expansion: even if someone adds
`elasticloadbalancing:*` back to the allowlist, the OU-level networking guard
still blocks ALB creation. Belt and suspenders.

### What remains allowed (deliberately)

| Resource | Why kept |
|---|---|
| VPC + subnets + IGW + route tables | Free infrastructure |
| Gateway VPC endpoints (S3, DynamoDB) | Free |
| EC2 instances (nano/micro/small) | Core compute |
| Lambda | Pay-per-use (risk acknowledged, future mitigation planned) |
| Fargate | Pay-per-use, quarantine handles runaway |
| ECS on EC2 | Size-limited by EC2 instance SCP |
| DynamoDB | Pay-per-use, on-demand pricing |
| S3 | Pay-per-use, egress is the risk |
| CloudFront | Pay-per-use (risk noted, future mitigation planned) |
| API Gateway | Pay-per-use |
| EventBridge, Step Functions, SQS, SNS | Pay-per-use, negligible idle cost |

## Policy parameters

### Org-root stack

| Parameter | Default | Purpose |
|---|---|---|
| `OrgRootTargetId` | NONE | Organization root ID (`r-XXXX`) or NONE for detached |
| `AllowedRegions` | 5 regions | Coarse region boundary |
| `PolicyNamePrefix` | home-guardrail | Name prefix for all policies |

### OU-level stack

| Parameter | Default | Purpose |
|---|---|---|
| `Ec2InstanceSizeTargetIds` | NONE | OU IDs for EC2 size control |
| `NetworkingCostGuardTargetIds` | NONE | OU IDs for networking cost guard |
| `ComputeCostGuardTargetIds` | NONE | OU IDs for compute cost guard |
| `StorageDbCostGuardTargetIds` | NONE | OU IDs for storage/database cost guard |

Each parameter accepts comma-separated OU IDs. Default NONE leaves the policy
detached. No identifiers are embedded in the repository.

## Deploy safely

Prerequisites: AWS CLI v2, SCP policy type enabled, `FullAWSAccess` retained,
and LandingZoneAdmin SSO credentials for the management account.

Create all policies detached:

```bash
cd scp-guardrails
./deploy.sh
```

Attach incrementally (example IDs, not real values):

```bash
./deploy.sh \
  --org-root-id r-a1b2 \
  --ec2-size-targets ou-abcd-11111111,ou-abcd-22222222 \
  --networking-targets ou-abcd-11111111,ou-abcd-22222222 \
  --compute-targets ou-abcd-11111111,ou-abcd-22222222 \
  --storage-db-targets ou-abcd-11111111,ou-abcd-22222222
```

The script:
1. Validates all inputs (org root format, OU ID format, region format)
2. Verifies caller is LandingZoneAdmin on the management account
3. Shows the complete attachment plan
4. Requires typing ATTACH for any non-NONE target
5. Deploys org-root stack first, then OU-level stack

For non-interactive use: `ATTACH_CONFIRMATION=ATTACH`.

Omitted target options become NONE (detached). Running `./deploy.sh` with no
arguments is a deliberate detach-all rollback.

## Quarantine remediation role protection

The baseline-security policy includes `ProtectQuarantineRemediationRole`: denies
modification/deletion of `home-cost-quarantine-remediation` in workload accounts.
Only the StackSet execution role (`stacksets-exec-*`) is exempted. This ensures
the cost-quarantine state machines can always assume their cross-account role.

## Effective policy behavior

Keep AWS's default `FullAWSAccess` SCP attached everywhere. These policies only
deny: they subtract permissions and never grant. Effective access is the
intersection of all inherited SCPs. An explicit deny in *any* applicable SCP wins.

AWS permits up to 10 SCPs per target (increased May 2026 from 5). Each policy
can be up to 10,240 characters (increased from 5,120). This design uses 4
policies at org root + 4 at OU level = 8 total per account, leaving headroom.

## Rollback

Fast rollback: rerun `./deploy.sh` without the affected target option. The
management account is exempt from SCPs and can always detach a policy.

All policies have `DeletionPolicy: Retain`. Deleting a stack does not remove
protections. To fully decommission: remove targets, verify, delete stack, then
explicitly delete retained policies from Organizations.

## Migration from single-stack design

The previous `scp-guardrails.yaml` (6 policies in one stack) remains in the
repository. Migration path:

1. Deploy new stacks detached alongside the existing stack
2. Attach new policies one at a time, verify workload compatibility
3. Detach equivalent old policies after new ones are proven
4. Delete old stack; explicitly delete retained old policies

## Validation

```bash
cfn-lint cloudformation/scp-org-baseline.yaml cloudformation/scp-ou-policies.yaml
bash -n deploy.sh
```

## Files

```text
scp-guardrails/
├── README.md
├── deploy.sh
└── cloudformation/
    ├── scp-org-baseline.yaml     # Org-root: security, regions, allowlist, commitments
    ├── scp-ou-policies.yaml      # OU-level: EC2 size, networking, compute, storage/DB
    └── scp-guardrails.yaml       # Legacy single-stack design (retained for migration)
```

## Future work (parked)

- **Fine-grained region policies at OU level**: main region (full access),
  S3-only backup region, list/describe/delete-only departing region, AI-only
  innovation regions
- **Lambda cost mitigation**: memory/concurrency limits via SCP conditions
  (pending condition key availability)
- **CloudFront risk mitigation**: origin shield, WAF requirements, or
  subscription-based protections
- **Fargate re-evaluation**: keep or deny based on usage patterns
