# rentlora-infra

> Terraform infrastructure for the Rentlora platform on AWS — provisions everything from VPC to EKS, RDS, SQS, S3, IRSA, and TLS certificates.

![Terraform](https://img.shields.io/badge/Terraform-1.x-7B42BC?logo=terraform&logoColor=white)
![AWS EKS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazonaws&logoColor=white)
![Karpenter](https://img.shields.io/badge/Autoscaling-Karpenter-FF9900)
![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo&logoColor=white)

---

## Overview

`rentlora-infra` is the single source of truth for all AWS infrastructure supporting the Rentlora platform. It is organized into reusable modules and environment stacks, with remote state stored in S3 and DynamoDB locking. All AWS credentials used by pods are provided through **IRSA** (IAM Roles for Service Accounts) — there are no static access keys anywhere in the system.

---

## Architecture

```
┌─────────────── stacks/cluster (shared, apply once) ──────────────────┐
│  VPC  │  EKS (managed node groups + Karpenter)  │  ECR  │  Route53   │
│  ACM (TLS cert)  │  ArgoCD (in-cluster)  │  kgateway  │  CI IAM Role │
└───────────────────────────────────────────────────────────────────────┘
                                │
              ┌─────────────────┴──────────────────┐
              ▼                                    ▼
   stacks/dev (per-env)                 stacks/prod (per-env)
   ├── RDS PostgreSQL                   ├── RDS PostgreSQL (deletion_protection)
   ├── SQS queues (property-sync,       ├── SQS queues
   │             booking-events)        ├── S3 + CloudFront
   ├── S3 + CloudFront                  ├── IRSA roles per service
   ├── IRSA roles per service           ├── SSM parameters
   └── SSM parameters                  └── CloudWatch log groups
```

---

## Repository Layout

```
rentlora-infra/
├── global/
│   └── s3-backend/         # Bootstrap: creates the S3 state bucket + DynamoDB lock table (run once)
│
├── modules/                # Reusable Terraform modules
│   ├── vpc/                # VPC, subnets, NAT gateway, route tables
│   ├── eks/                # EKS cluster, managed node groups, OIDC provider
│   ├── karpenter/          # Karpenter controller + node IAM roles
│   ├── rds/                # RDS PostgreSQL instance (with pgvector support)
│   ├── sqs/                # SQS queues (standard + FIFO) with DLQs
│   ├── s3/                 # S3 bucket + CloudFront distribution (OAC)
│   ├── ecr/                # ECR repositories per service
│   ├── irsa/               # IRSA role per service with scoped IAM policies
│   ├── ssm/                # SSM Parameter Store entries
│   ├── route53/            # Hosted zone + DNS records
│   └── acm/                # ACM TLS certificate (DNS-validated)
│
└── stacks/
    ├── cluster/            # Shared infra: VPC, EKS, ECR, Route53, ACM, CI role
    ├── dev/                # Dev environment: RDS, SQS, S3, IRSA, SSM
    └── prod/               # Prod environment: same + deletion_protection=true, larger instances
```

---

## Stacks

### `stacks/cluster` — Shared Infrastructure

Provisions resources shared by all environments. Apply once.

| Resource | Details |
|---|---|
| **VPC** | 3 AZs, public + private subnets, NAT gateway |
| **EKS** | Managed cluster with a bootstrap node group (system pods) + Karpenter for app workloads |
| **Karpenter** | Controller IAM role, node instance profile |
| **ECR** | One repository per service (7 total) |
| **Route53** | Hosted zone for `rentlora.in` |
| **ACM** | Wildcard TLS certificate (`*.rentlora.in`), DNS-validated |
| **CI IAM Role** | Least-privilege role for GitHub Actions OIDC federation |

### `stacks/dev` and `stacks/prod` — Per-Environment

| Resource | Details |
|---|---|
| **RDS** | PostgreSQL with pgvector extension enabled |
| **SQS** | `property-sync` queue (standard) + `booking-events` queue with DLQs |
| **S3 + CloudFront** | Property image storage with CloudFront OAC (bucket stays private) |
| **IRSA roles** | One scoped IAM role per service, annotated to each EKS ServiceAccount |
| **SSM Parameters** | All non-sensitive config (DB endpoint, queue URLs, model IDs, SES sender, etc.) |
| **CloudWatch** | Log groups per service |

Production stack additionally sets `deletion_protection = true` on RDS and uses larger instance types.

---

## First-Time Setup

```bash
# Step 1 — Bootstrap state backend (local state, run once per AWS account)
cd global/s3-backend
terraform init
terraform apply

# Step 2 — Provision shared cluster infrastructure
cd ../../stacks/cluster
terraform init
terraform apply

# Step 3 — Provision dev environment
cd ../dev
terraform init
terraform apply

# Step 4 — Provision prod environment
cd ../prod
terraform init
terraform apply
```

After Step 2, point your domain registrar's nameservers to the Route53 NS records printed in the output (`route53_name_servers`). ACM certificate validation completes automatically once DNS propagates.

---

## GitHub Actions Integration

Set the following secret in the `rentlora` application repository:

```
AWS_CI_ROLE_ARN = <ci_role_arn from stacks/cluster outputs>
```

Create GitHub Environments named `cluster`, `dev`, and `production`. The `production` environment should require a reviewer approval gate before the prod Terraform apply runs.

---

## Key Terraform Outputs

After applying each stack, collect these outputs for use in `rentlora-helm`:

| Stack | Output | Used In |
|---|---|---|
| `cluster` | `acm_cert_arn` | `rentlora-helm/environments/*/values.yaml` |
| `cluster` | `ci_role_arn` | GitHub Actions secret |
| `cluster` | `route53_name_servers` | Domain registrar NS records |
| `dev` | `irsa_role_arns` | `rentlora-helm/environments/dev/values.yaml` |
| `dev` | `rds_endpoint` | SSM Parameter Store (automatic) |

---

## Security Design

- **No static AWS credentials** — all pod access via IRSA; CI access via OIDC federation
- **Each service has a scoped IRSA role** — least-privilege; no service can access another's secrets
- **Secrets in AWS Secrets Manager** — DB passwords and JWT secret; never in SSM, never in code
- **S3 bucket is private** — CloudFront accesses it via OAC; no public bucket access
- **RDS not publicly accessible** — deployed in private subnets; accessible only from within VPC
- **Production RDS** has `deletion_protection = true` — manual approval required to destroy

---

## Remote State

State is stored in S3 with DynamoDB locking — bootstrapped by `global/s3-backend`:

```hcl
terraform {
  backend "s3" {
    bucket         = "rentlora-terraform-state"
    key            = "stacks/cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "rentlora-terraform-locks"
    encrypt        = true
  }
}
```

Each stack uses a unique key path.

---

## Project Context

This repository is part of the Rentlora microservices platform:

| Repository | Role |
|---|---|
| [`rentlora`](../rentlora) | Application source — all services + frontend |
| **`rentlora-infra`** (this repo) | Terraform — AWS infrastructure |
| [`rentlora-helm`](../rentlora-helm) | Helm charts + Argo CD GitOps |
