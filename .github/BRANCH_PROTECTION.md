# Branch protection — trunk-based

`main` is the trunk. Infra changes land via `feature/*` → PR → `main`. PRs run
`terraform fmt/validate`, `terraform plan` (posted as a comment), and the Trivy IaC scan;
the `iac-checks` gate must pass plus a review before merge. Merging to `main` applies the
stacks in order `cluster → dev → prod`, each gated by its GitHub Environment approval.

## Required GitHub setup (one-time)

**Repository secrets:**
- `AWS_CI_ROLE_ARN` — arn of the `rentlora-eks-ci` role (OIDC)

**Environments** (Settings → Environments), each with required reviewers as desired:
- `cluster`, `dev`, `production` — the apply jobs pause here for approval

**Branch protection on `main`** — UI or `gh` (requires `gh auth login`):

```bash
gh api -X PUT repos/rentlora/rentlora-infra/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[contexts][]=iac-checks' \
  -f 'enforce_admins=true' \
  -f 'required_pull_request_reviews[required_approving_review_count]=1' \
  -f 'required_pull_request_reviews[dismiss_stale_reviews]=true' \
  -f 'required_pull_request_reviews[require_code_owner_reviews]=true' \
  -f 'required_linear_history=true' \
  -f 'allow_force_pushes=false' \
  -f 'allow_deletions=false' \
  -F 'restrictions=null'
```
