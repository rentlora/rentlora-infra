# Bootstrap & Operations

How to stand up Rentlora's infrastructure the **first time**, and how applies work
**after** that. Also: switching AWS accounts.

## Why the first apply is local (chicken-and-egg)

The GitHub Actions pipeline (`terraform-apply.yml`) authenticates to AWS by assuming the
`rentlora-eks-ci` role via **OIDC**. But that role, the **OIDC provider**, *and* the
**S3 state backend** are all things Terraform *creates*. On day one none of them exist —
so Actions has nothing to assume and nowhere to store state.

➡️ **You run the first apply locally with admin AWS credentials. After that, GitHub Actions takes over.**

---

## Prerequisites (local, one time)

- AWS CLI configured with **admin** credentials for the target account
  (`aws sts get-caller-identity` should return your account)
- `terraform` ≥ 1.9, `kubectl`, `helm`
- The domain **`rentlora.in`** registered (needed for Route53 + ACM)

---

## Step 1 — State backend (local state)

Creates the S3 bucket `rentlora-terraform-state` + DynamoDB lock table
`rentlora-terraform-locks` that every other stack uses. This stack itself uses **local**
state (it's what bootstraps the remote backend).

```bash
cd global/s3-backend
terraform init
terraform apply
```

## Step 2 — Cluster stack (the big one)

Creates VPC, EKS, ECR, the **OIDC provider + `rentlora-eks-ci` role**, ACM cert, Route53
zone, and installs the platform addons (ArgoCD, kgateway, Karpenter, external-dns,
metrics-server, AWS LB controller).

```bash
cd ../../stacks/cluster
terraform init      # uses the S3 backend created in step 1
terraform apply
```

> ⚠️ **If apply hangs on `aws_acm_certificate_validation`** it's DNS delegation. The
> Route53 zone is created here, but ACM can only validate once the public internet resolves
> `rentlora.in` to *this* zone. Take the name servers from the output and set them at your
> domain registrar, then re-run `terraform apply`:
> ```bash
> terraform output route53_name_servers
> ```

## Step 3 — Dev and Prod stacks

RDS, SQS, S3/CDN, IRSA roles, SSM secrets per environment.

```bash
cd ../dev  && terraform init && terraform apply
cd ../prod && terraform init && terraform apply
```

## Step 4 — Point kubectl at the cluster

```bash
aws eks update-kubeconfig --name rentlora-eks --region us-east-1
kubectl get nodes        # should show the 2 system nodes
```

---

## Step 5 — Fill the Helm placeholders (in `rentlora-helm`)

The chart env values + gateway carry `<ACCOUNT_ID>` / `<ACM_CERT_ARN>` placeholders.
Pull the real values from Terraform outputs:

```bash
# from rentlora-infra/stacks/cluster
terraform output -raw ecr_registry        # <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
terraform output -raw acm_cert_arn         # <ACM_CERT_ARN>  (gateway/gatewayparameters.yaml)

# from rentlora-infra/stacks/dev  (and stacks/prod for prod values)
terraform output -json irsa_role_arns      # per-service IRSA role ARNs
```

Edit in `rentlora-helm`:
- `environments/dev/values.yaml` + `environments/prod/values.yaml` → `global.ecrRegistry`, `irsaRoleArns`
- `gateway/gatewayparameters.yaml` → `<ACM_CERT_ARN>`

Commit + push to `rentlora-helm` (ArgoCD picks it up).

## Step 6 — Apply the cluster-scoped GitOps resources

```bash
# from rentlora-helm
kubectl apply -f karpenter/                 # NodePool + EC2NodeClass
kubectl apply -f gateway/                   # GatewayParameters + Gateway + HTTPRoute
kubectl apply -f argocd/app-of-apps.yaml    # ApplicationSets (dev + prod)

# verify
kubectl get applications -n argocd                     # 6 apps Synced + Healthy
kubectl get gateway,svc -n rentlora-dev                # NLB address appears
curl https://dev.rentlora.in/healthz                   # frontend
curl https://dev.rentlora.in/api/properties            # property-service
```

---

## After bootstrap — it's all GitHub Actions

Once the OIDC role and backend exist, **never apply locally again**:
- **Infra change** → PR to `rentlora-infra` → merge → Actions runs `apply` (cluster→dev→prod, each gated by its Environment approval)
- **App change** → PR to `rentlora` → merge → build/push image → ArgoCD deploys dev → promote prod via `deploy.yml`

---

## Switching to a different AWS account later

Account IDs are **not hardcoded in code** — only in a GitHub secret, the Terraform backend
config, and Helm placeholders. To move accounts:

1. Point local AWS creds at the new account (`aws configure` / profile).
2. **Re-run the bootstrap** (Steps 1–3) in the new account — this recreates the OIDC
   provider + `rentlora-eks-ci` role there. The role's trust is org-wide
   (`repo:rentlora/*`), so it's account-agnostic — no trust edits needed.
3. Update the GitHub secret on **both** repos:
   ```bash
   echo "arn:aws:iam::<NEW_ACCOUNT>:role/rentlora-eks-ci" | gh secret set AWS_CI_ROLE_ARN -R rentlora/rentlora
   echo "arn:aws:iam::<NEW_ACCOUNT>:role/rentlora-eks-ci" | gh secret set AWS_CI_ROLE_ARN -R rentlora/rentlora-infra
   ```
4. Re-fill the Helm placeholders (Step 5) from the **new** account's outputs.
5. Re-delegate `rentlora.in` to the new account's Route53 name servers if the zone moved.

(If you also move the Terraform state, create a fresh `global/s3-backend` in the new
account and `terraform init -migrate-state` each stack, or start from clean state.)
