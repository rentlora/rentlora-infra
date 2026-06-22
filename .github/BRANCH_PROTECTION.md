# Branch protection — trunk-based

`main` is the trunk. All infra changes land via a short-lived branch → PR → `main`.

## Branch naming

| Branch | Purpose |
|---|---|
| `feature/*` | New infra resources, module changes |
| `hotfix/*` | Urgent fixes that need fast-track review |

No long-lived environment branches. GitHub Environment gates replace what env-branches used to do.

## What happens on PR

Every PR to `main` runs (must all pass before merge):

1. `terraform fmt -check` — formatting
2. `terraform validate` — syntax + provider schema
3. Trivy IaC scan — HIGH/CRITICAL gate
4. `terraform plan` — output posted as PR comment for all 3 stacks
5. `iac-checks` — aggregator status (branch protection watches this one)
6. 1 approved review from CODEOWNERS (`@iyas311`)

## What happens after merge to main

| Stack | Trigger | Who applies |
|---|---|---|
| `cluster` | `workflow_dispatch` only | Manual — someone runs Actions → Terraform → Run workflow → cluster |
| `dev` | auto on push to `main` | Plan runs → `dev` environment gate → apply |
| `prod` | `workflow_dispatch` only | Manual — someone runs Actions → Terraform → Run workflow → prod |

Cluster and prod never apply from a code push. The plan always runs first and is visible
in the job summary before the environment gate fires.

## Required GitHub setup (one-time)

**Repository secret:**
- `AWS_CI_ROLE_ARN` — ARN of the `rentlora-eks-ci` IAM role (OIDC, no static keys)

**Environments** (Settings → Environments):
- `cluster` — required reviewers recommended (shared VPC + EKS control plane)
- `dev` — can be ungated or 1 reviewer
- `production` — required reviewers mandatory

**Branch protection on `main`:**

```bash
gh api -X PUT repos/rentlora/rentlora-infra/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[contexts][]=iac-checks' \
  -f 'enforce_admins=false' \
  -f 'required_pull_request_reviews[required_approving_review_count]=1' \
  -f 'required_pull_request_reviews[dismiss_stale_reviews]=true' \
  -f 'required_pull_request_reviews[require_code_owner_reviews]=true' \
  -f 'required_linear_history=true' \
  -f 'allow_force_pushes=false' \
  -f 'allow_deletions=false' \
  -F 'restrictions=null'
```

> `enforce_admins=false` lets you bypass the gate during bootstrap. Tighten to `true`
> once the pipeline is stable and you never need emergency direct pushes.
