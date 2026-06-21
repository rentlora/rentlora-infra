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

**Do this in two phases** so the apply doesn't hang on certificate validation. The ACM cert
validates via DNS, which only works once the domain is delegated to the new Route53 zone —
but you only get the zone's nameservers *after* it's created. So: create the zone, delegate,
then finish.

### 2a. Create the Route53 zone first, read its nameservers

```bash
cd ../../stacks/cluster
terraform init      # uses the S3 backend created in step 1
terraform apply -target=module.dns_tls.aws_route53_zone.main
terraform output route53_name_servers     # 4 × ns-xxx.awsdns-xx.{com,net,org,co.uk}
```

### 2b. Delegate the domain at GoDaddy (registrar for rentlora.in)

1. GoDaddy → **Domain Portfolio** → click **rentlora.in**
2. **Nameservers → Change → "I'll use my own nameservers"** (Enter my own / advanced)
3. Replace with the **4 Route53 values** (drop any trailing dot) → Save
4. Verify it propagated (minutes–couple hours):
   ```bash
   dig +short NS rentlora.in     # should return the awsdns... servers, not GoDaddy's
   ```

This is a **full-domain delegation** — Route53 becomes authoritative for `rentlora.in`, so
`external-dns` can later create `dev.rentlora.in` / `rentlora.in` records for the NLB.

### 2c. Full apply (ACM validation now completes)

```bash
terraform apply
```

> ⚠️ If apply still hangs on `aws_acm_certificate_validation`, DNS hasn't propagated yet —
> re-check `dig +short NS rentlora.in`, wait, then re-run `terraform apply`.

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

The chart env values + gateway carry `<ACCOUNT_ID>` / `<ACM_CERT_ARN>` placeholders (the ECR
region and IRSA role names are already correct in the templates — only these two need filling).

**One command** — the helper reads the Terraform outputs and patches all three files:

```bash
cd ../../rentlora-helm        # or wherever rentlora-helm is checked out
scripts/fill-values.sh        # pass the infra path as arg 1 if not a sibling dir
git diff                      # review
git commit -am "fill account id + ACM arn from terraform outputs" && git push
```

It patches `environments/dev/values.yaml`, `environments/prod/values.yaml`, and
`gateway/gatewayparameters.yaml`. Once pushed, ArgoCD picks up the values.

<details><summary>Manual alternative</summary>

```bash
# from rentlora-infra/stacks/cluster
terraform output -raw ecr_registry    # account id is the first segment
terraform output -raw acm_cert_arn
```
Replace `<ACCOUNT_ID>` and `<ACM_CERT_ARN>` in the three files above.
</details>

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
