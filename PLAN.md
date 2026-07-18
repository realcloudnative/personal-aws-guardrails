# SCP Service Allowlist Analysis

Comprehensive review of every IAM namespace currently permitted by the
`home-guardrail-service-allowlist` SCP. The goal: identify what each service
does, whether we need it, and what expensive resources lurk inside.

## Methodology

The service allowlist uses `NotAction` + `Effect: Deny`. Any namespace listed
below is **allowed**; everything else is hard-denied. This table evaluates each
against the home setup's pattern: serverless-first, AI/LLM-heavy, cost-paranoid,
agentic-age-aware.

## Service analysis

### AI & Machine Learning

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `bedrock:*` | Amazon Bedrock (foundation models) | ✅ Core | Model invocation at scale; Provisioned Throughput ($thousands/mo); Custom Model Training ($$$); Knowledge Bases with OpenSearch (creates AOSS); Guardrails per-request cost | Deny `bedrock:CreateProvisionedModelThroughput`, `bedrock:CreateModelCustomizationJob`. Consider denying Knowledge Base creation (spawns AOSS). Token-based billing is pay-per-use but unbounded. |
| `bedrock-agentcore:*` | Bedrock Agent Core (agents runtime) | ✅ Yes | Invocation volume; tools calling other services | Bounded by what other services are allowed. Monitor via budgets. |
| `bedrock-mantle:*` | Bedrock Powered by AWS Mantle (3rd-party models) | ✅ Yes | Marketplace subscriptions for model access; per-token costs | `DenyMarketplaceSubscribeOutsideBedrockMantle` already scopes this. Costs are pay-per-use. |
| `aws-external-anthropic:*` | Direct Anthropic integration | ⚠️ Probably | Same as Bedrock token costs | Pay-per-use. Monitor. |
| `transcribe:*` | Amazon Transcribe (speech-to-text) | ⚠️ Maybe | Batch jobs on large audio files; real-time streaming at volume | Pay-per-second. Low risk unless processing hours of audio. |
| `translate:*` | Amazon Translate (text translation) | ⚠️ Maybe | High-volume batch translation | Pay-per-character. Low risk. |

### Compute

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `ec2:*` | EC2 (instances, VPCs, networking) | ✅ Core | Already mitigated: instance size ≤ small, NAT GW denied, ELB denied, TGW denied, VPN denied, provisioned IOPS denied, dedicated tenancy denied | Remaining risks: Elastic IPs ($3.60/mo each if unattached since Feb 2024); EBS volumes accumulating; Snapshots growing unbounded; EC2 Image Builder AMIs consuming storage |
| `autoscaling:*` | EC2 Auto Scaling | ✅ Yes | Can maintain fleets of instances | Limited by instance size SCP. Quarantine scales to 0. |
| `ecs:*` | Elastic Container Service | ✅ Yes | Fargate tasks at scale; Fargate Windows (2x cost) | Consider denying Fargate Windows via condition. Quarantine handles runaway. |
| `ecr:*` | Elastic Container Registry | ✅ Yes | Storage accumulation (large images, no lifecycle policy) | Low per-GB cost ($0.10/GB/mo). Lifecycle policies recommended but not SCP-enforceable. |
| `ecr-public:*` | ECR Public Gallery | ⚠️ Maybe | Minimal cost risk | Free to pull. Only risk is publishing bandwidth. |
| `lambda:*` | AWS Lambda | ✅ Core | **HIGH RISK if misconfigured**: 10GB memory × 10,000 concurrent × long duration = 6,000 vCPU equivalents at Lambda rates. Infinite loops via EventBridge/SQS/Step Functions. Provisioned Concurrency ($$$). | Deny `lambda:PutProvisionedConcurrencyConfig`. Memory/concurrency limits not yet SCP-enforceable via condition keys. Reserved concurrency is free but unreserved pool is shared. **PARKED: needs deeper research.** |
| `apprunner:*` | App Runner | ⚠️ Maybe | Minimum 1 instance always running (~$5/mo per service); easy to forget | Consider removing if not used. Each service costs even when idle. |
| `imagebuilder:*` | EC2 Image Builder | ⚠️ Rarely | Launches EC2 instances for builds; stores AMIs (EBS snapshots) | Instance limited by size SCP. AMI storage is low-cost. May be needed for custom AMIs. |

### Serverless & Integration

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `apigateway:*` | API Gateway (REST, HTTP, WebSocket) | ✅ Core | WebSocket connections at scale; REST API with no throttle facing DDoS; edge-optimized (CloudFront) unintentional | Pay-per-request. Very low idle cost. WAF recommended for public APIs. |
| `execute-api:*` | API Gateway invocation namespace | ✅ Yes (required by API GW) | Same as above | Companion to `apigateway:*`. |
| `events:*` | Amazon EventBridge | ✅ Core | Event replay at volume; Schema Discovery charges; Cross-account event buses at volume | Pay-per-event, essentially free at home scale. |
| `scheduler:*` | EventBridge Scheduler | ✅ Yes | Minimal cost (first 14M invocations/mo free) | Essentially free. |
| `schemas:*` | EventBridge Schema Registry | ⚠️ Low use | Schema Discovery mode charges per event | Tiny cost. Keep for convenience. |
| `pipes:*` | EventBridge Pipes | ✅ Yes | Pay-per-request; source polling costs | Very low at home scale. |
| `states:*` | Step Functions | ✅ Core | Standard Workflows: $25/million state transitions; Express: per-duration. At home scale = negligible. | Essentially free at low volume. Used by quarantine itself. |
| `sns:*` | Simple Notification Service | ✅ Yes | SMS messages ($0.01-0.75 each); high-volume fan-out | Deny SMS via `sns:Publish` with protocol condition? Not SCP-enforceable. Monitor. |
| `sqs:*` | Simple Queue Service | ✅ Yes | Essentially free (1M requests/mo free tier) | No risk. |

### Storage

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `s3:*` | S3 (object storage) | ✅ Core | **Data egress** ($0.09/GB); Requestor Pays misconfiguration; S3 Transfer Acceleration ($0.04-0.08/GB); Glacier restore fees; Intelligent-Tiering monitoring fees at scale; accidental public exposure | Consider denying `s3:PutBucketAccelerateConfiguration`. Egress is the main risk and not SCP-preventable (it's a consequence of GETs). |
| `s3-object-lambda:*` | S3 Object Lambda | ⚠️ Rarely | Lambda invocations + data processing per GET | Pay-per-use. Only charges if actually used. |
| `dynamodb:*` | DynamoDB | ✅ Core | **Provisioned capacity mode** (forgotten tables with high RCU/WCU); Global Tables (replication costs); On-Demand can spike under load but auto-scales billing | Consider denying provisioned mode? No SCP condition key for billing mode. DAX already denied. Global Table replication is pay-per-use. |
| `elasticfilesystem:*` | EFS (Elastic File System) | ⚠️ Maybe | Provisioned Throughput mode ($6/MB/s/mo); multi-AZ by default ($0.30/GB/mo standard); can grow unbounded | Consider denying `elasticfilesystem:CreateFileSystem` or limiting to One Zone via condition? No condition key exists. Alternatively: just deny it and use S3 instead. **Candidate for removal.** |

### Networking & DNS

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `route53:*` | Route 53 (DNS hosting) | ✅ Yes | $0.50/hosted zone/month; query charges negligible | Very low cost. Essential for custom domains. |
| `route53domains:*` | Route 53 domain registration | ⚠️ Rarely | Domain registration fees ($10-50/year) | One-time costs, not recurring surprise. Keep for convenience. |
| `route53resolver:*` | Route 53 Resolver (DNS firewall, endpoints) | ⚠️ Maybe | **Resolver Endpoints: $0.125/hr per ENI = ~$90/mo per endpoint pair** | Deny `route53resolver:CreateResolverEndpoint`? Probably not needed for home. DNS Firewall rules are cheap. **Candidate for deny or removal.** |
| `cloudfront:*` | CloudFront (CDN) | ✅ Core | Origin shield ($0.0090/request); high-bandwidth origins; invalidations at volume; real-time logs to Kinesis | Pay-per-use. New Security Savings Bundle helps. Shield Advanced auto-attach risk (separate service, already denied). |
| `cloudfront-keyvaluestore:*` | CloudFront KV Store | ✅ Yes (if using CF Functions) | Negligible | Tiny per-read cost. |

### Security & Identity

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `iam:*` | IAM (Identity and Access Management) | ✅ Required | Free service. Roles Anywhere certificate management is operational complexity, not cost. | No cost risk. |
| `sso:*` | IAM Identity Center (SSO) | ✅ Required | Free service | No cost risk. |
| `sso-directory:*` | SSO Directory | ✅ Required (IdC internal) | Free | No cost risk. |
| `sso-oauth:*` | SSO OAuth flows | ✅ Required (IdC internal) | Free | No cost risk. |
| `identitystore:*` | Identity Store | ✅ Required (IdC internal) | Free | No cost risk. |
| `sts:*` | Security Token Service | ✅ Required | Free | No cost risk. |
| `guardduty:*` | GuardDuty (threat detection) | ✅ Yes | **EKS/S3/Malware scanning can get expensive at volume**; base detector ~$4/mo for management events | Already have EKS denied so EKS Runtime Monitoring won't apply. S3 Data Events protection can be costly. Runtime Monitoring on ECS Fargate adds cost. |
| `kms:*` | Key Management Service | ✅ Required | $1/mo per CMK; API call charges at high volume ($0.03/10K requests) | Low cost unless creating many keys. |
| `acm:*` | Certificate Manager | ✅ Yes | Public certificates: free. Private CA: **$400/mo** | Deny `acm-pca:CreateCertificateAuthority`! Wait — `acm-pca` is a separate namespace not in our allowlist. Already blocked. ✓ |
| `cognito-idp:*` | Cognito User Pools | ⚠️ Maybe | First 50K MAU free; beyond: $0.0055/MAU. SMS for MFA costs. Advanced security features: $0.05/MAU | Low risk at home scale. |
| `cognito-identity:*` | Cognito Identity Pools (federated) | ⚠️ Maybe | Free (just vends credentials) | No cost risk. |
| `cognito-sync:*` | Cognito Sync (legacy) | ❌ Probably not | Deprecated service | **Candidate for removal.** |

### Monitoring & Operations

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `cloudwatch:*` | CloudWatch (metrics, alarms, dashboards) | ✅ Required | Custom metrics ($0.30/metric/mo); Dashboards ($3/dashboard/mo); high-resolution metrics (1-sec); Contributor Insights; Evidently | Metric accumulation is the main risk. Basic monitoring free. |
| `logs:*` | CloudWatch Logs | ✅ Required | **Ingestion: $0.50/GB**; Storage: $0.03/GB/mo; Logs Insights queries; Live Tail. Lambda verbose logging can easily push GB/day | Set retention policies. Consider denying `logs:CreateLogGroup` without retention? Not SCP-enforceable. Budget is the backstop. |
| `cloudtrail:*` | CloudTrail | ✅ Yes | Management events: free (Event History). **Creating a trail: first trail free, additional trail $2/100K events; data events $0.10/100K** | No trail exists (by design). If one is created accidentally, it charges. Consider denying `cloudtrail:CreateTrail` unless deliberate? |
| `cloudshell:*` | CloudShell | ✅ Yes (convenience) | Free (1GB persistent storage) | No cost risk. |
| `ssm:*` | Systems Manager (Parameter Store, Session Manager, etc.) | ✅ Yes | Advanced Parameter Store tier ($0.05/parameter/mo); Automation executions; OpsCenter OpsItems; **Patch Manager on-demand instances** | Advanced params are the risk. Standard tier is free (up to 10K params, 4KB each). |
| `ssmmessages:*` | SSM Messages (Session Manager transport) | ✅ Yes (required by SSM) | Free (transport layer) | No cost risk. |
| `ec2messages:*` | EC2 Messages (SSM agent transport) | ✅ Yes (required by SSM) | Free (transport layer) | No cost risk. |
| `servicequotas:*` | Service Quotas | ✅ Yes | Free | No cost risk. |
| `tag:*` | Tag Editor / Resource Groups Tagging | ✅ Yes | Free | No cost risk. |
| `health:*` | AWS Health | ✅ Yes | Free | No cost risk. |

### Developer Tools

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `cloudformation:*` | CloudFormation | ✅ Core | Free for AWS resources; **3rd-party resources $0.0009/operation**; StackSets operations are free | No meaningful cost risk. |
| `codebuild:*` | CodeBuild | ⚠️ Maybe | Build minutes: $0.005-0.20/min depending on compute type; builds left running; **GPU instances available** | Deny large/GPU compute types? No SCP condition key for compute type. Monitor build duration. |
| `codepipeline:*` | CodePipeline | ⚠️ Maybe | $1/active pipeline/mo (V1) or $0.002/action (V2) | Low cost. |
| `codedeploy:*` | CodeDeploy | ⚠️ Maybe | Free for EC2/Lambda; ECS blue/green is free | No cost risk. |
| `codecommit:*` | CodeCommit | ❌ Deprecated | **AWS deprecated CodeCommit July 2024**. No new repos. | **Remove from allowlist.** Dead service. |
| `codeartifact:*` | CodeArtifact | ⚠️ Maybe | Storage ($0.05/GB/mo) + requests ($0.05/10K requests) | Low cost unless hoarding many packages. |

### Data & Analytics

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `athena:*` | Athena (S3 SQL queries) | ✅ Yes | $5/TB scanned (per query); unpartitioned tables scan everything | Partition data properly. Low risk at home data volumes. |
| `glue:*` (limited) | Glue Data Catalog only | ✅ Yes (Athena dependency) | First 1M objects free; storage and requests free up to limits | Already limited to catalog operations only. No ETL jobs, no crawlers. ✓ |
| `mediaconvert:*` | MediaConvert (video transcoding) | ⚠️ Rarely | Per-minute output pricing; 4K/8K transcoding expensive | Pay-per-use only. No idle cost. Only charges if actively transcoding. |

### Billing & Account (management plane)

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `account:*` | AWS Account management | ✅ Required | Free | No cost risk. |
| `billing:*` | Billing console | ✅ Required | Free | No cost risk. |
| `budgets:*` | AWS Budgets | ✅ Required | First 2 budgets free; $0.02/day/additional budget | Negligible. |
| `ce:*` | **Cost Explorer** | ✅ Required | Free for console; API: $0.01/request (paginated) | Low cost. Used by cost analysis. |
| `cur:*` | Cost & Usage Reports | ✅ Yes | Report delivery to S3 (storage cost) | Negligible. |
| `consolidatedbilling:*` | Consolidated Billing | ✅ Required | Free | No cost risk. |
| `freetier:*` | Free Tier tracking | ✅ Yes | Free | No cost risk. |
| `invoicing:*` | Invoice management | ✅ Yes | Free | No cost risk. |
| `payments:*` | Payment methods | ✅ Yes | Free | No cost risk. |
| `tax:*` | Tax settings | ✅ Yes | Free | No cost risk. |
| `bcm-data-exports:*` | Billing data exports | ✅ Yes | Free (replaces legacy CUR) | No cost risk. |
| `cost-optimization-hub:*` | Cost Optimization Hub | ✅ Yes | Free | No cost risk. |
| `purchase-orders:*` | Purchase Orders | ⚠️ Unnecessary | Free | No cost risk, but unnecessary for personal. Keep anyway (harmless). |
| `aws-portal:*` | AWS Management Console (billing views) | ✅ Required | Free (legacy namespace) | No cost risk. |
| `aws-marketplace:Subscribe` | Marketplace subscription (scoped) | ✅ Required (Bedrock models) | Already guarded by `CalledViaLast` condition | Only Bedrock Mantle can trigger. ✓ |
| `aws-marketplace:ViewSubscriptions` | View Marketplace subscriptions | ✅ Yes | Free | No cost risk. |

### Other

| Namespace | Service | Need? | Expensive risks | Mitigation ideas |
|---|---|---|---|---|
| `artifact:*` | AWS Artifact (compliance reports) | ✅ Yes | Free | No cost risk. |
| `organizations:*` | AWS Organizations | ✅ Required | Free | No cost risk. |
| `support:*` | AWS Support | ✅ Yes | Business/Enterprise support is $$$ but plan choice is account-level, not API-driven | Basic support free. |
| `supportplans:*` | Support Plans | ✅ Yes | See above | Cannot accidentally upgrade support plan via API without billing agreement. |
| `trustedadvisor:*` | Trusted Advisor | ✅ Yes | Free (basic checks); full checks require Business+ support | No cost risk at Basic tier. |
| `ram:*` | Resource Access Manager | ⚠️ Rarely | Free (sharing mechanism) | No cost risk. Needed if sharing VPC subnets cross-account. |

---

## Summary: action items

### Immediate removals (hard deny by removing from allowlist)

| Namespace | Reason |
|---|---|
| `codecommit:*` | Deprecated by AWS (July 2024). Dead service. |
| `cognito-sync:*` | Deprecated. Legacy mobile sync. |

### Strong candidates for removal

| Namespace | Reason | Risk if removed |
|---|---|---|
| `elasticfilesystem:*` | $0.30/GB/mo standard; grows unbounded; S3 is cheaper for most use cases | Can't mount NFS in Lambda/Fargate (some ML workloads use it) |
| `route53resolver:*` | Resolver endpoints cost $90/mo; DNS Firewall is cheap but rarely needed at home | Lose ability to create DNS Firewall rules (minimal loss) |
| `apprunner:*` | Minimum $5/mo per service even idle; Lambda/API GW is better for home | Can't use App Runner (use Lambda + API GW instead) |
| `mediaconvert:*` | Niche; pay-per-use but easy to accidentally transcode large video | Can't transcode video (use ffmpeg on EC2 if needed) |

### New OU-level denies to add (defense-in-depth within allowed services)

| Action to deny | Service | Monthly cost prevented | Notes |
|---|---|---|---|
| `bedrock:CreateProvisionedModelThroughput` | Bedrock | $thousands | Provisioned throughput is enterprise-only pricing |
| `bedrock:CreateModelCustomizationJob` | Bedrock | $hundreds-thousands | Fine-tuning jobs are expensive |
| `lambda:PutProvisionedConcurrencyConfig` | Lambda | $50+/mo per allocation | Provisioned concurrency charges even when idle |
| `s3:PutBucketAccelerateConfiguration` | S3 | $0.04-0.08/GB transferred | Transfer Acceleration charges per GB |
| `route53resolver:CreateResolverEndpoint` | Route 53 | $90/mo per endpoint pair | If keeping namespace in allowlist |
| `cloudtrail:CreateTrail` | CloudTrail | $2-50+/mo | Prevent accidental trail creation; Event History is free |
| `ec2:AllocateAddress` | EC2 | $3.60/mo per unused EIP | Since Feb 2024, all EIPs cost money. Consider denying or monitoring. |
| `elasticfilesystem:CreateFileSystem` | EFS | $0.30/GB/mo | If keeping namespace in allowlist |

### Parked for deeper research

| Topic | Why parked |
|---|---|
| Lambda runaway mitigation | No SCP condition key for memory/concurrency. Need to explore account-level concurrency limits, budgets, or alternative approaches. |
| CloudFront egress risk | New Security Savings Bundle and WAF integration may help. Need to evaluate CloudFront subscription options. |
| DynamoDB provisioned mode | No SCP condition key to force on-demand. IAM policy can enforce this per-role but not org-wide via SCP. |
| S3 egress/requestor-pays | Fundamental limitation: SCP can't prevent GET-driven egress. Budget alerts are the only backstop. |
| CloudWatch Logs ingestion | Can't enforce retention via SCP. Organizational default retention might be possible. Need research. |
| GuardDuty feature costs | Runtime Monitoring, S3 Data Events, Malware scanning add $10-100+/mo. Can disable features but not via SCP. |
| CodeBuild GPU/large instances | No SCP condition key for build compute type. |

### Not actionable via SCP (awareness only)

| Risk | Why not SCP-fixable | Mitigation path |
|---|---|---|
| Lambda infinite loops | SCP can't limit invocation count/duration | Account-level concurrency limit (Lambda settings), budget alerts |
| Log volume explosion | SCP can't limit ingestion | Log group retention policies, budget alerts |
| DynamoDB on-demand spikes | SCP can't limit throughput | Table-level settings, budget alerts |
| SNS SMS costs | SCP can't limit SMS protocol | Spending limit in SNS settings |
| S3 data egress | SCP can't limit GETs | VPC endpoint policies, CloudFront OAC, budget alerts |

---

## Proposed execution order

1. **Quick wins**: Remove `codecommit`, `cognito-sync` from allowlist
2. **Evaluate removals**: Decide on `elasticfilesystem`, `route53resolver`, `apprunner`, `mediaconvert`
3. **Add OU-level denies**: Bedrock provisioned throughput, Lambda provisioned concurrency, S3 Transfer Acceleration, CloudTrail trail creation, EFS creation (if kept in allowlist), Route 53 resolver endpoints (if kept)
4. **Fine-grained region policies**: Implement the OU-level region differentiation (main region, S3-only backup, list/describe/delete departing, AI innovation)
5. **Lambda deep-dive**: Research account-level concurrency limits and whether they can be SCP-protected
6. **CloudFront risk**: Evaluate subscription models and WAF requirements
