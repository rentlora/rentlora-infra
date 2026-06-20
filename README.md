# rentlora-infra

Terraform infrastructure for the Rentlora platform on AWS EKS.

## Architecture

- **1 EKS cluster** (shared) with 2 namespaces: `rentlora-dev` and `production`
- **Karpenter** for node autoscaling (EC2 NodePool); bootstrap node group runs system pods
- **kgateway** (Gateway API) for L7 routing; NLB with ACM TLS termination
- **ArgoCD** for GitOps deploys from `rentlora-helm`
- **IRSA** for all AWS access — no static credentials anywhere

## Repo layout

```
global/s3-backend/    # bootstrap: run once manually
modules/              # reusable building blocks
stacks/
  cluster/            # shared: VPC, EKS, addons, ECR, Route53, ACM
  dev/                # per-env: RDS, SQS, S3/CDN, IRSA, SSM
  prod/               # per-env: same, with deletion_protection=true
```

## First-time setup

```bash
# 1. Bootstrap state bucket (run once, local state)
cd global/s3-backend
terraform init && terraform apply

# 2. Apply shared cluster stack
cd ../../stacks/cluster
terraform init && terraform apply

# 3. Apply dev environment
cd ../dev
terraform init && terraform apply

# 4. Apply prod environment
cd ../prod
terraform init && terraform apply
```

## After cluster apply

Point your domain registrar's nameservers to the Route53 zone NS records printed in
`stacks/cluster` outputs (`route53_name_servers`). ACM cert validation completes
automatically once DNS propagates.

## GitHub Actions

Set the following repository secret:
- `AWS_CI_ROLE_ARN` — the CI IAM role ARN from `stacks/cluster` outputs (`ci_role_arn`)

Create GitHub Environments named `cluster`, `dev`, and `production` — the `production`
environment should require a reviewer approval before the prod apply runs.
