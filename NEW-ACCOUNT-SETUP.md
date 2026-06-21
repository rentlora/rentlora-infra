# New AWS Account — Full Setup Runbook

End-to-end guide to stand up the entire Rentlora platform on a **fresh AWS account**,
written after a real first-run so every bug we hit is either already fixed in code or
documented here as a manual step. Read this top-to-bottom before you start.

> **TL;DR of what bites you:** most failures we hit are now fixed in the Terraform/Helm
> code and **won't recur** (see [§9](#9-bugs-already-fixed-in-code-wont-recur)). A short
> list of steps are **not** in code and you **must** do them by hand each time — they're
> flagged with 🖐 throughout and summarized in [§10](#10-manual-steps-not-in-code-will-recur).

---

## 1. What is account-specific (the things you change)

| Item | Where | Current value (example) |
|---|---|---|
| AWS account ID | filled into Helm by `fill-values.sh`; never hardcoded in TF | `280646578520` |
| Region | `stacks/*/terraform.tfvars` + backend blocks | `us-east-1` |
| Cluster name | `stacks/cluster/terraform.tfvars` | `rentlora-eks` |
| Domain | `stacks/cluster/terraform.tfvars` | `rentlora.in` |
| GitHub org / repo | `stacks/cluster/terraform.tfvars` (OIDC trust) | `rentlora` |
| State bucket / lock table | `global/s3-backend` + `backend "s3"` blocks | `rentlora-terraform-state` / `rentlora-terraform-locks` |
| `AWS_CI_ROLE_ARN` | GitHub secret (app + infra repos) | `arn:aws:iam::<acct>:role/rentlora-eks-ci` |

If the new account uses a **different region or domain**, edit each
`stacks/*/terraform.tfvars` and the `region`/`bucket` lines in every `versions.tf`
`backend "s3"` block (backends can't read variables — they must be literal).

---

## 2. Prerequisites

**Local tools:** `aws` CLI (configured with **admin** creds for the new account),
`terraform` ≥ 1.9, `kubectl`, `helm`, `gh`, `git`, `docker`.

**Confirm you're pointed at the new account:**
```bash
aws sts get-caller-identity        # Account must be the NEW one
```

**A registered domain** you control (Route53 will become its authoritative DNS).

---

## 3. Phase 0 — GitHub setup (one-time per org)

If reusing the existing `rentlora` org, most of this already exists. For a brand-new org:

1. **Secrets** (set after the infra exists — see Phase 1/7):
   - `AWS_CI_ROLE_ARN` — repo or org level, scoped to `rentlora` + `rentlora-infra`
   - `HELM_REPO_TOKEN` — fine-grained PAT, **Resource owner = the org**, repo = `rentlora-helm`, permission **Contents: Read/Write** only. 🖐
   - `SONAR_TOKEN`, `SNYK_TOKEN`, `SLACK_WEBHOOK_URL` — optional scanners/notifications.

2. **Org PAT policy** (only if the org blocks fine-grained PATs): enable at
   `https://github.com/organizations/<org>/settings/personal-access-tokens`. 🖐

3. **`gh` needs org scope** to set org-level secrets:
   ```bash
   gh auth refresh -h github.com -s admin:org
   ```

4. **GitHub Environments** (Settings → Environments): `cluster`, `dev`, `production`
   with reviewers on the gated ones. 🖐

> **OIDC, not static keys:** the CI role is assumed via GitHub OIDC. The OIDC provider
> + `rentlora-eks-ci` role are **created by Terraform** in the cluster stack (`modules/ecr`),
> so they don't exist until Phase 1. The trust is org-wide (`repo:<org>/*`), so all repos
> can assume it. When you switch accounts you just update the `AWS_CI_ROLE_ARN` secret to
> the new account's role ARN — no trust edits.

---

## 4. Phase 1 — Terraform state backend (local state)

Chicken-and-egg: the S3 backend, OIDC role, and cluster are all things Terraform creates,
so the **first apply runs locally** with admin creds.

```bash
cd rentlora-infra/global/s3-backend
terraform init        # local state — this stack bootstraps the remote backend
terraform apply
```

Creates `rentlora-terraform-state` (S3) + `rentlora-terraform-locks` (DynamoDB).

---

## 5. Phase 2 — Cluster stack (two-phase for DNS)

Creates VPC, EKS (**v1.32**), ECR, OIDC provider + CI role, ACM cert, Route53 zone, and the
platform addons (ArgoCD, kgateway, Karpenter, AWS LB controller, external-dns,
metrics-server) + EKS managed addons (vpc-cni, coredns, kube-proxy, EBS CSI,
cloudwatch-observability, pod-identity-agent).

### 5a. Create the Route53 zone first, read its nameservers
```bash
cd ../../stacks/cluster
terraform init
terraform apply -target=module.dns_tls.aws_route53_zone.main
terraform output route53_name_servers     # 4 × ns-xxx.awsdns-xx.{com,net,org,co.uk}
```

### 5b. 🖐 Delegate the domain at your registrar (e.g. GoDaddy)
Domain → **Nameservers → "I'll use my own"** → paste the **4 Route53 values** → Save.
Verify (install `dig`/`drill`, or use `nslookup`):
```bash
nslookup -type=NS rentlora.in 8.8.8.8     # must return the awsdns... servers
```
ACM validation in the next step **hangs** until this propagates (minutes–couple hours).

### 5c. Full apply
```bash
terraform apply
```

> ⚠️ **If the apply dies mid-way** (network blip, timeout): just re-run `terraform apply`.
> State in S3 + the DynamoDB lock make it safe and idempotent — it resumes where it stopped.
> We hit a transient S3 DNS error once; the re-run completed cleanly.

**Save the outputs** (used in Phase 4):
```bash
terraform output -raw ecr_registry        # <acct>.dkr.ecr.us-east-1.amazonaws.com
terraform output -raw acm_cert_arn
```

---

## 6. Phase 3 — Dev (and later Prod) stacks

Per-env RDS, SQS, S3/CDN, IRSA roles, SSM params, Secrets Manager entries.

```bash
cd ../dev
terraform init
terraform apply
```

> 🐛 **Secrets Manager "already exists":** if you (re)apply after a partial run, you may see
> `ResourceExistsException` for `/rentlora/<env>/db-password` or `/jwt-secret`. These are
> orphans from a half-finished apply. Delete them **by ARN** (Git Bash mangles leading-slash
> names — use the ARN), then re-apply:
> ```bash
> for arn in $(aws secretsmanager list-secrets --region us-east-1 \
>     --query 'SecretList[?contains(Name,`rentlora/dev`)].ARN' --output text); do
>   aws secretsmanager delete-secret --secret-id "$arn" --region us-east-1 \
>     --force-delete-without-recovery
> done
> ```

**Do prod the same way (`cd ../prod`) once dev is verified healthy.**

---

## 7. Phase 4 — Fill Helm placeholders

```bash
cd ../../../rentlora-helm        # adjust to where rentlora-helm is checked out
scripts/fill-values.sh           # reads cluster TF outputs, patches the 3 files
git diff                         # confirm <ACCOUNT_ID>/<ACM_CERT_ARN> replaced
git commit -am "fill account id + ACM arn from terraform outputs" && git push
```
Patches `environments/dev/values.yaml`, `environments/prod/values.yaml`,
`gateway/gatewayparameters.yaml`. (Run from a sibling checkout, or pass the infra path
as arg 1.)

> If doing **dev only first**, also comment out the `rentlora-prod` ApplicationSet in
> `argocd/app-of-apps.yaml` until `stacks/prod` is applied — otherwise ArgoCD tries to
> deploy into a `production` namespace whose IRSA/RDS/SSM don't exist yet.

---

## 8. Phase 5 — Cluster-scoped manifests + first deploy

```bash
aws eks update-kubeconfig --name rentlora-eks --region us-east-1
kubectl get nodes        # 2 system nodes Ready
```

### 8a. 🖐 Install the upstream Gateway API CRDs — **required, not in Terraform**
kgateway ships only *its own* CRDs (GatewayParameters). The standard `Gateway`/`HTTPRoute`
kinds come from the Kubernetes Gateway API project and must be installed separately:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```
Without this, `kubectl apply -f gateway/` fails with *"no matches for kind Gateway"*.

### 8b. Apply Karpenter + Gateway + ArgoCD
```bash
cd rentlora-helm
kubectl apply -f karpenter/                          # NodePool + EC2NodeClass
kubectl create namespace rentlora-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f gateway/                            # → AWS LB Controller provisions an NLB
kubectl apply -f argocd/app-of-apps.yaml             # ApplicationSet(s) → 6 apps per env
```

Watch the gateway get an address and external-dns write the record:
```bash
kubectl get gateway -n rentlora-dev                  # PROGRAMMED=True, ADDRESS=k8s-...elb...
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> \
  --query "ResourceRecordSets[?contains(Name,'dev.rentlora.in')]"
```

### 8c. 🖐 Build + push images (apps stay `ImagePullBackOff` until this runs)
ECR repos start empty. Trigger the app pipeline to build/scan/push all 6 services and bump
the dev image tag (which ArgoCD then syncs):
```bash
cd rentlora        # the app repo
git commit --allow-empty -m "ci: trigger first dev deploy"
git push
gh run watch -R <org>/rentlora
```
The `build` → `bump-dev` → ArgoCD path lands the images; pods go Running, Karpenter scales
a node if the system nodes are full.

### 8d. Verify end-to-end
```bash
curl https://dev.rentlora.in/healthz
curl https://dev.rentlora.in/api/properties
kubectl get applications -n argocd        # all Synced + Healthy
```

---

## 9. Bugs already fixed in code (won't recur)

These bit us on the first run and are **now committed**, so a fresh account won't hit them:

| Bug | Symptom | Fix (committed) |
|---|---|---|
| **EKS 1.29 retired** | `InvalidParameterException: unsupported Kubernetes version 1.29` | `cluster_version` default → **1.32** in `modules/eks/variables.tf` |
| **EBS CSI crashloop** | addon stuck `CREATING` 20 min; controller `UnauthorizedOperation` on `ec2:DescribeAvailabilityZones` | IRSA role `rentlora-eks-ebs-csi` + `AmazonEBSCSIDriverPolicy`, wired via `service_account_role_arn` in `modules/eks/main.tf` |
| **Karpenter crashloop** | `panic: NonExistentQueue` | added `sqs:GetQueueUrl/ReceiveMessage/DeleteMessage/GetQueueAttributes` to the karpenter policy in `modules/addons/main.tf` |
| **kgateway repo dead** | `404 ... index.yaml` | migrated to OCI `oci://cr.kgateway.dev/kgateway-dev/charts/{kgateway-crds,kgateway}` `v2.0.0` + separate CRDs release |
| **trivy-action version** | `Unable to resolve action aquasecurity/trivy-action@0.24.0` | pinned to `@master` in build-scan-push + terraform-apply |
| **pytest import error** | `starlette.testclient requires httpx` | `pip install ... httpx` in `.github/actions/python-checks` |
| **HCL semicolons / config drift** | `terraform fmt/validate` failures | all stacks multi-line + `terraform.tfvars`-driven, no hardcoded defaults |

> ⚠️ **Two timing caveats** (fixed in code but eventual-consistency can still nag): the EBS
> CSI and Karpenter IRSA roles now exist *before* their pods, so the controllers come up
> with the right role. If on a very fast apply a controller pod starts before IAM/SA
> propagation, it may crashloop briefly — `kubectl -n <ns> delete pod -l <selector>` forces
> a clean restart that re-injects IRSA. We only needed this on the first run when the role
> was added *after* the addon; a from-scratch apply shouldn't need it.

---

## 10. Manual steps not in code (WILL recur) 🖐

These are **not** in Terraform/Helm — you must do them every new account/cluster:

1. **Registrar nameserver delegation** (Phase 5b) — point your domain at the Route53 NS,
   or ACM never validates.
2. **Gateway API CRDs** (Phase 8a) — `kubectl apply` the `standard-install.yaml`.
3. **Build + push images** (Phase 8c) — run the pipeline once so ECR isn't empty.
4. **GitHub tokens + org PAT policy + `gh auth refresh -s admin:org`** (Phase 0).
5. **GitHub Environments + branch protection** (Phase 0) — gates aren't created by code.
6. **Local helm repo registration** (see §11) — environment-specific to the machine running
   `terraform apply`.
7. **App-runtime AWS enablement** — Bedrock model access (AI service) and SES sender
   verification (booking emails) are **console toggles**, not Terraform.

---

## 11. Gotcha: local helm repo cache (Windows / fresh machine)

The Terraform `helm` provider resolves HTTP chart URLs against your **local** helm config.
If that config is empty or has a stale entry, you get a misleading error referencing some
other repo's index (we saw `gloo-index.yaml: cannot find the file`), and the four
HTTP-based charts (LB controller, metrics-server, ArgoCD, external-dns) fail to download.

**Fix — register the repos once on the machine running the apply:**
```bash
helm repo add eks            https://aws.github.io/eks-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add argo           https://argoproj.github.io/argo-helm
helm repo add external-dns   https://kubernetes-sigs.github.io/external-dns
helm repo update
```
(OCI charts — karpenter, kgateway — are unaffected; they bypass the index lookup.)

---

## 12. Switching accounts — minimal checklist

If the code is already deployed once and you're moving to a new account:

1. `aws configure` → point at the new account (`aws sts get-caller-identity` to confirm).
2. Edit `stacks/*/terraform.tfvars` if region/domain/cluster-name differ; edit `backend
   "s3"` blocks if the state bucket/region differ.
3. Run **Phases 1 → 3** (recreates state backend, OIDC provider, CI role, cluster, envs).
4. Update GitHub secret on both repos:
   ```bash
   echo "arn:aws:iam::<NEW_ACCT>:role/rentlora-eks-ci" | gh secret set AWS_CI_ROLE_ARN -R <org>/rentlora
   echo "arn:aws:iam::<NEW_ACCT>:role/rentlora-eks-ci" | gh secret set AWS_CI_ROLE_ARN -R <org>/rentlora-infra
   ```
5. Re-delegate the domain to the **new** account's Route53 NS (Phase 5b).
6. Run **Phase 4** (`fill-values.sh` repoints `<ACCOUNT_ID>`/`<ACM_CERT_ARN>` to the new account).
7. Run **Phases 5 → 8** (CRDs, manifests, first image build).
8. Don't forget the §10 manual steps and §11 helm repos on the new machine.

---

## 13. Verification checklist

- [ ] `aws sts get-caller-identity` → new account
- [ ] `terraform output` (cluster) → ecr_registry, acm_cert_arn, route53_name_servers
- [ ] `nslookup -type=NS <domain>` → awsdns servers (delegation live)
- [ ] ACM cert **ISSUED** (`aws acm list-certificates`)
- [ ] `kubectl get pods -A` → all Running (argocd, kgateway, karpenter, kube-system, external-dns, amazon-cloudwatch)
- [ ] `kubectl get gateway -n rentlora-dev` → PROGRAMMED=True, has an ELB address
- [ ] Route53 has `dev.<domain>` A record → NLB
- [ ] ECR repos have images (after pipeline run)
- [ ] `kubectl get applications -n argocd` → Synced + Healthy
- [ ] `curl https://dev.<domain>/healthz` → 200

---

## 14. Teardown (reverse order)

```bash
# 1. Remove cluster-scoped k8s objects first (so the NLB/Route53 records are cleaned by controllers)
kubectl delete -f rentlora-helm/argocd/app-of-apps.yaml
kubectl delete -f rentlora-helm/gateway/
# 2. Destroy stacks newest → oldest
cd rentlora-infra/stacks/prod    && terraform destroy
cd ../dev     && terraform destroy
cd ../cluster && terraform destroy      # may need the gateway NLB gone first
cd ../../global/s3-backend && terraform destroy   # last — holds the state
```
> Delete the Gateway/Service **before** destroying the cluster stack, or the NLB lingers and
> blocks VPC deletion. If `terraform destroy` on the cluster hangs on the VPC, check for a
> leftover ELB or ENIs from the LB controller.
