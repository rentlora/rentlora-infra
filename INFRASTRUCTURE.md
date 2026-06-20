# Rentlora Infrastructure Guide

This document explains every piece of the `rentlora-infra` Terraform repo — what it creates, why, and how it all connects.

---

## The Big Picture

```
Internet
   │
   ▼ HTTPS (port 443)
Route53 (DNS) ──► NLB (Network Load Balancer)
                       │  ACM cert terminates TLS here
                       ▼ HTTP
                  kgateway (Envoy proxy, inside cluster)
                       │
                  ┌────┴────────────────────────┐
                  ▼                             ▼
            /* → frontend (React)    /api/* → backend services
                                          (property, booking, ai, admin, ai-search)
```

All 6 containers run in **Amazon EKS** (Kubernetes). AWS services (RDS, SQS, S3, Bedrock, SES) are accessed by pods using **IRSA** — pod identity via IAM, no passwords or keys stored anywhere in Kubernetes.

---

## Repository Structure

```
rentlora-infra/
│
├── global/s3-backend/          ← Run this ONCE before anything else
│
├── modules/                    ← Reusable building blocks
│   ├── vpc/                    ← Networking
│   ├── eks/                    ← Kubernetes cluster
│   ├── addons/                 ← Platform tools (Karpenter, ArgoCD, etc.)
│   ├── ecr/                    ← Container image registries
│   ├── dns-tls/                ← Route53 + ACM certificate
│   ├── rds/                    ← PostgreSQL database
│   ├── sqs/                    ← Message queues
│   ├── s3-cdn/                 ← Property images bucket + CloudFront
│   ├── iam-irsa/               ← Per-service AWS permissions
│   └── ssm-secrets/            ← App configuration in Parameter Store
│
├── stacks/
│   ├── cluster/                ← Shared infra (VPC, EKS, ECR, DNS) — apply once
│   ├── dev/                    ← Dev environment (RDS, SQS, S3, IAM, SSM)
│   └── prod/                   ← Prod environment (same as dev, stricter settings)
│
└── .github/workflows/
    └── terraform-apply.yml     ← CI/CD pipeline
```

---

## Module-by-Module Explanation

---

### `global/s3-backend` — State Storage Bootstrap

**What it does:** Creates the S3 bucket and DynamoDB table that Terraform uses to store its state files.

**Why it exists:** Terraform needs somewhere to track what it has created. This must exist before any other stack can run. It uses local state only (the only exception in the whole repo).

**Run once manually:**
```bash
cd global/s3-backend
terraform init
terraform apply
```

**Creates:**
- S3 bucket: `rentlora-terraform-state` (versioned, encrypted)
- DynamoDB table: `rentlora-terraform-locks` (prevents two people running Terraform at the same time)

---

### `modules/vpc` — Networking

**What it does:** Creates all the networking infrastructure that EKS and RDS live inside.

**CIDR layout:**
```
VPC: 10.0.0.0/16
│
├── Public subnets:       10.0.1.0/24, 10.0.2.0/24     (NLB lives here)
├── Private app subnets:  10.0.11.0/24, 10.0.12.0/24   (EKS nodes live here)
└── Database subnets:     10.0.31.0/24, 10.0.32.0/24   (RDS lives here)
```

**Key decisions:**
- Uses 2 Availability Zones (us-east-1a, us-east-1b) for redundancy
- Single NAT Gateway (saves cost; pods can reach internet for AWS API calls)
- Public subnets are tagged so the AWS LB Controller knows where to place the NLB
- Private subnets are tagged so Karpenter knows which subnets to launch nodes in

**Uses:** `terraform-aws-modules/vpc/aws` community module (handles the EKS tagging automatically)

---

### `modules/eks` — Kubernetes Cluster

**What it does:** Creates the EKS cluster (Kubernetes control plane + worker nodes).

**Key settings:**
- Kubernetes version: 1.29
- Node type: t3.medium
- Bootstrap node group: 2 nodes minimum, maximum 3 — these only run system pods (Karpenter, CoreDNS, etc.)
- App workload nodes are managed by **Karpenter** (see addons module)

**EKS Managed Addons** (AWS patches these automatically):

| Addon | What it does |
|-------|-------------|
| `vpc-cni` | Gives each pod its own VPC IP address |
| `coredns` | DNS resolution inside the cluster |
| `kube-proxy` | Routes network traffic between pods |
| `aws-ebs-csi-driver` | Allows pods to use EBS volumes (Persistent Volume Claims) |
| `amazon-cloudwatch-observability` | Sends container logs and metrics to CloudWatch |

**OIDC Provider:** The module automatically creates an OIDC provider for the cluster — this is required for IRSA (pod IAM roles) to work.

**Uses:** `terraform-aws-modules/eks/aws` community module

---

### `modules/addons` — Platform Tools

**What it does:** Installs all the platform-level tools into the cluster via Helm.

| Tool | Namespace | What it does |
|------|-----------|-------------|
| **Karpenter** | `karpenter` | Auto-scales EC2 nodes based on pending pod requirements. Much faster than Cluster Autoscaler (provisions in ~30 seconds). |
| **AWS LB Controller** | `kube-system` | Watches for `Service type=LoadBalancer` and provisions an NLB in AWS automatically. |
| **kgateway** | `kgateway-system` | Envoy-based L7 proxy that routes traffic: `/*` → frontend, `/api/*` → backend services. |
| **metrics-server** | `kube-system` | Provides CPU/memory metrics so HPA (auto-scaling) works. |
| **ArgoCD** | `argocd` | GitOps tool — watches `rentlora-helm` repo and auto-deploys when image tags change. |
| **external-dns** | `external-dns` | Watches the kgateway Service and creates Route53 A records automatically when the NLB is provisioned. |

**Karpenter specifics:**
- Has its own IAM role (IRSA) to call EC2 APIs
- Node role: Karpenter-launched EC2 instances use a separate IAM role with EKS worker permissions
- Interruption queue: SQS queue that receives AWS spot-interruption notices so Karpenter can gracefully drain nodes before they're terminated

**TLS / ACM note:** The `aws-load-balancer-controller` adds an annotation to the NLB Service with the ACM certificate ARN. This makes the NLB terminate HTTPS using the ACM certificate — no private keys ever touch the cluster.

---

### `modules/ecr` — Container Image Registries

**What it does:** Creates 6 ECR repositories (one per service) and sets up CI/CD access.

**Repositories created:**
- `rentlora-frontend`
- `rentlora-property-service`
- `rentlora-booking-service`
- `rentlora-ai-service`
- `rentlora-admin-service`
- `rentlora-ai-search-service`

**Lifecycle policy per repo:**
- Untagged images deleted after 1 day
- Keep last 10 tagged images (tagged with `v*` or `sha-*`)

**GitHub Actions OIDC:** Creates an AWS IAM OIDC provider for GitHub Actions so the build pipeline can push images to ECR without storing any AWS credentials as GitHub secrets — it uses a short-lived token instead.

**CI IAM Role permissions:**
- Push/pull to all 6 ECR repos
- `eks:DescribeCluster` (needed for `kubectl` in deploy workflow)

---

### `modules/dns-tls` — Route53 + ACM Certificate

**What it does:** Creates the DNS zone and SSL certificate for the domain.

**What gets created:**
1. **Route53 Hosted Zone** for `rentlora.in`
2. **ACM Wildcard Certificate** covering:
   - `rentlora.in` (apex domain)
   - `*.rentlora.in` (all subdomains: `dev.rentlora.in`, `api.rentlora.in`, etc.)
3. **DNS validation records** (Route53 records that prove to ACM we own the domain)

**After apply — IMPORTANT:** Copy the Route53 nameservers from the Terraform output (`route53_name_servers`) and set them in your domain registrar. ACM certificate validation completes automatically once DNS propagates (usually 5–10 minutes).

**How TLS works end-to-end:**
```
Browser → rentlora.in (Route53 A record → NLB)
         ↓
        NLB port 443: ACM cert terminates HTTPS
         ↓
        NLB port 80: plain HTTP to kgateway inside cluster
         ↓
        kgateway routes to the right service
```

---

### `modules/rds` — PostgreSQL Database

**What it does:** Creates the PostgreSQL database and stores the password securely.

**Settings:**
- Engine: PostgreSQL 15.7
- Instance: `db.t3.micro`
- Storage: 20GB gp3
- Database name: `rentlora`, user: `postgres`
- Lives in the private DB subnets (not reachable from the internet)
- Backups: 7 days retention

**Dev vs Prod difference:**
- Dev: `deletion_protection = false`, `skip_final_snapshot = true` (easier to destroy for testing)
- Prod: `deletion_protection = true`, `skip_final_snapshot = false` (takes a final snapshot before destroy)

**Password handling:**
- A random 24-character password is generated by Terraform
- Stored in **AWS Secrets Manager** at path `/rentlora/{env}/db-password`
- Apps fetch it at startup using IRSA — the password is never in any code, config file, or K8s manifest

**pgvector:** The `CREATE EXTENSION IF NOT EXISTS vector` is run by the app at startup (see `property-service/main.py`), no custom RDS parameter group needed.

---

### `modules/sqs` — Message Queues

**What it does:** Creates the two SQS queues the app uses for async processing.

**Queue 1 — `rentlora-{env}-property-sync` (standard queue)**
- Used by: `property-service` (publisher) → `ai-search-service` (consumer)
- Purpose: When a property is created/updated, publish to this queue. `ai-search-service` picks it up, generates a Bedrock embedding, and stores it in the DB for semantic search.
- DLQ: After 3 failed processing attempts, message goes to `property-sync-dlq` (held 14 days for debugging)

**Queue 2 — `rentlora-{env}-booking-events.fifo` (FIFO queue)**
- Used by: `booking-service` (publisher only for now)
- Purpose: Booking events (created, confirmed, cancelled) published here. FIFO ensures ordering per booking.
- DLQ: After 5 failed attempts → `booking-events-dlq.fifo`

**Why FIFO for bookings?** Booking state transitions must be processed in order (can't process "cancelled" before "confirmed").

---

### `modules/s3-cdn` — Property Images

**What it does:** Creates the storage and delivery infrastructure for property images.

**Flow:**
```
App uploads image → S3 bucket (uploads/ prefix)
                        ↓
                   Lambda triggers
                        ↓
                   Resized copy saved (uploads/resized/)
                        ↓
                   Browser fetches via CloudFront CDN (cached globally)
```

**Components:**
- **S3 bucket:** `rentlora-{env}-property-images` — private, only CloudFront can read
- **CloudFront distribution:** OAC (Origin Access Control) — modern way to give CloudFront-only access to S3. `PriceClass_100` = US + Europe edge locations only (cheaper)
- **Lambda function:** Node.js 20, uses `sharp` library to resize images to max 1200×900px, 85% JPEG quality

---

### `modules/iam-irsa` — Service IAM Roles

**What it does:** Creates one IAM role per microservice. Each role is scoped to exactly the AWS permissions that service needs.

**How IRSA works:**
1. Each Kubernetes ServiceAccount is annotated with a role ARN
2. When a pod starts, AWS injects a token into the pod
3. The app's AWS SDK exchanges this token for temporary credentials
4. The trust policy on the IAM role only allows the specific K8s namespace + ServiceAccount to assume it

**Permissions per service:**

| Service | Can do |
|---------|--------|
| `property-service` | Send to property-sync SQS, read/write property images S3 |
| `ai-search-service` | Receive from property-sync SQS, call Bedrock (Titan embeddings) |
| `booking-service` | Send to booking-events SQS, send emails via SES, publish to SNS |
| `ai-service` | Call Bedrock (Nova Lite chat + Titan embeddings) |
| `admin-service` | DB only (no extra AWS permissions needed) |
| **All 5** | Read Secrets Manager + SSM Parameter Store under `/rentlora/{env}/*` |

---

### `modules/ssm-secrets` — App Configuration

**What it does:** Writes all the configuration values that apps read at startup.

**Two storage tiers:**

**Secrets Manager** (sensitive, $0.40/secret/month):
| Path | What |
|------|------|
| `/rentlora/{env}/db-password` | Database password (written by RDS module) |
| `/rentlora/{env}/jwt-secret` | 64-char random secret for JWT token signing |

**SSM Parameter Store** (free standard tier):
| Path | Value |
|------|-------|
| `/rentlora/{env}/db-endpoint` | RDS hostname |
| `/rentlora/{env}/db-user` | `postgres` |
| `/rentlora/{env}/db-name` | `rentlora` |
| `/rentlora/{env}/aws-region` | `us-east-1` |
| `/rentlora/{env}/s3-bucket-name` | Images bucket name |
| `/rentlora/{env}/cdn-domain` | CloudFront domain |
| `/rentlora/{env}/sqs/property-sync-url` | Queue URL |
| `/rentlora/{env}/sqs/booking-events-url` | Queue URL |
| `/rentlora/{env}/ses-sender-email` | `noreply@rentlora.in` |
| `/rentlora/{env}/ai/nova-model-id` | `amazon.nova-lite-v1:0` |
| `/rentlora/{env}/ai/embedding-model-id` | `amazon.titan-embed-text-v2:0` |
| `/rentlora/{env}/service/ai-search-url` | Internal K8s DNS URL |
| `/rentlora/{env}/service/booking-url` | Internal K8s DNS URL |

Apps read these at startup via `config.py` using the IRSA identity — no `.env` files needed in production.

---

## Stacks — How Everything Composes

### `stacks/cluster` — Shared Infrastructure

**Apply once. Shared by both dev and prod.**

Composes: `vpc` + `eks` + `addons` + `ecr` + `dns-tls`

**State file:** `s3://rentlora-terraform-state/cluster/terraform.tfstate`

**Key outputs (consumed by dev/prod stacks):**
- `oidc_provider_arn` — needed to create IRSA roles
- `cluster_name` — needed for IRSA trust policies
- `db_subnet_group_name` — needed for RDS placement
- `vpc_id` — needed for RDS security group
- `acm_cert_arn` — used in Helm chart annotations for NLB HTTPS
- `route53_name_servers` — set these in your domain registrar
- `ci_role_arn` → set as `AWS_CI_ROLE_ARN` GitHub secret

---

### `stacks/dev` and `stacks/prod` — Per-Environment

**Apply per environment. Reads cluster outputs via `terraform_remote_state`.**

Composes: `rds` + `sqs` + `s3-cdn` + `ssm-secrets` + `iam-irsa`

**State files:**
- `s3://rentlora-terraform-state/dev/terraform.tfstate`
- `s3://rentlora-terraform-state/prod/terraform.tfstate`

**Key outputs (used in `rentlora-helm` values):**
- `irsa_role_arns` — map of `service-name → IAM role ARN` for ServiceAccount annotations
- `cdn_domain` — CloudFront URL for frontend to display images
- `rds_endpoint` — written to SSM, apps read it directly

---

## CI/CD Pipeline (`terraform-apply.yml`)

```
Pull Request:
  validate (fmt + validate all 3 stacks)
    └── plan (posts diff as PR comment for all 3 stacks)

Push to main:
  validate
    └── apply-cluster  (requires "cluster" environment approval)
          └── apply-dev  (requires "dev" environment approval)
                └── apply-prod  (requires "production" environment approval + reviewer)
```

**No AWS credentials stored as secrets.** Uses GitHub Actions OIDC to get a short-lived token, then assumes the CI IAM role created by `modules/ecr`.

**Required GitHub setup:**
1. Create Environments named `cluster`, `dev`, `production` in repo settings
2. Add required reviewers to `production` environment
3. Add secret `AWS_CI_ROLE_ARN` = output of `terraform output ci_role_arn` from cluster stack

---

## Execution Order (First Time)

```bash
# Step 1 — Bootstrap (run once, never again)
cd global/s3-backend && terraform init && terraform apply

# Step 2 — Shared cluster (VPC, EKS, ArgoCD, kgateway, ECR, Route53, ACM)
cd ../../stacks/cluster && terraform init && terraform apply
# → Copy route53_name_servers output to your domain registrar
# → Copy ci_role_arn output to GitHub secret AWS_CI_ROLE_ARN

# Step 3 — Dev environment
cd ../dev && terraform init && terraform apply

# Step 4 — Prod environment (when ready)
cd ../prod && terraform init && terraform apply
```

---

## Verification Checklist

After all stacks are applied, run these checks:

```bash
# Configure kubectl
aws eks update-kubeconfig --name rentlora-eks --region us-east-1

# Cluster health
kubectl get nodes                          # should show 2 Ready nodes
kubectl get ns                             # should show rentlora-dev, production

# Platform pods
kubectl get pods -n kube-system            # coredns, aws-node, kube-proxy running
kubectl get pods -n kgateway-system        # kgateway-* running
kubectl get pods -n karpenter              # karpenter-* running
kubectl get pods -n argocd                 # argocd-server, argocd-repo-server running
kubectl get pods -n external-dns           # external-dns-* running

# AWS resources
aws sqs list-queues --queue-name-prefix rentlora   # shows 4 queues (2 per env + DLQs)
aws ecr describe-repositories                       # shows 6 repos
aws secretsmanager list-secrets                     # shows db-password + jwt-secret per env
aws ssm get-parameters-by-path --path /rentlora/dev/ --recursive   # shows 13 params

# ACM certificate
aws acm list-certificates                  # should show ISSUED status (not PENDING_VALIDATION)
```

---

## Cost Estimate (dev environment, us-east-1)

| Resource | Monthly Cost |
|----------|-------------|
| EKS cluster | ~$72 |
| EC2 nodes (2× t3.medium, ~730hrs) | ~$60 |
| RDS db.t3.micro | ~$15 |
| NAT Gateway | ~$32 |
| CloudFront + S3 (light usage) | ~$5 |
| SQS (free tier covers dev usage) | ~$0 |
| Secrets Manager (2 secrets) | ~$0.80 |
| Route53 hosted zone | ~$0.50 |
| **Total (approx)** | **~$185/month** |

> Karpenter will scale nodes down when idle, reducing EC2 cost during off-hours.

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Node autoscaling | Karpenter | Faster provisioning (~30s vs ~5min), right-sizes nodes |
| TLS | ACM on NLB | AWS manages renewal; no private keys in cluster |
| DNS automation | external-dns | Auto-creates Route53 records when NLB is provisioned |
| GitOps | ArgoCD | Watches `rentlora-helm`; CI just bumps image tags |
| Secrets | Secrets Manager + SSM | Direct-fetch at startup via IRSA; nothing sensitive in Git or K8s manifests |
| VPC/EKS modules | Community (`terraform-aws-modules`) | Handle EKS subnet tagging correctly; battle-tested |
| Cluster topology | 1 cluster, 2 namespaces | Cost-efficient for a project; production isolation via namespace + NetworkPolicy |
