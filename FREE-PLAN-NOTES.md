# AWS Free Plan — changes & gotchas

This account (`611467706284`) is on AWS's restricted **Free Plan** (the 2025 model: ~$100–200
credit, hard config restrictions, and the account **auto-closes after 6 months or when credits
run out** unless you upgrade to a paid plan). This file records every change made *because of*
the Free Plan, what to revert when you go paid, and the restrictions you may still hit.

> **Reality:** EKS control plane (~$73/mo) is **not free** on any plan, so a 24/7 cluster will
> burn the credits. For real long-running use, **upgrade to a paid plan** (Billing → Account) —
> it removes every restriction below at once.

---

## 1. Changes FORCED by Free-Plan restrictions

| Setting | File | Before | After | Why |
|---|---|---|---|---|
| RDS `backup_retention_period` | `modules/rds/main.tf` | `7` | **`0`** | `FreeTierRestrictionError` — Free Plan caps automated backups. `0` = no automated daily backups (manual snapshots still allowed). |

**Revert on paid plan:** set `backup_retention_period` back to `7` (or per-env). The DB is
unaffected — it's just the backup policy.

> ⚠️ With `0`, prod has **no automatic point-in-time recovery**. Take manual snapshots if prod
> holds data you care about: `aws rds create-db-snapshot --db-instance-identifier rentlora-prod-... --db-snapshot-identifier manual-YYYYMMDD`

---

## 2. Changes CHOSEN for cost (free/budget account)

Not forced by the plan, but done to keep the bill low:

| Change | File | What |
|---|---|---|
| Karpenter NodePool | `rentlora-helm/karpenter/nodepool.yaml` | `spot` + `on-demand`, types `t3.small` / `c7i-flex.large` / `m7i-flex.large` |
| dev compute | `environments/dev/values.yaml` | `nodeSelector: spot`, `replicaCount: 1`, `hpa.minReplicas: 1` |
| prod compute | `environments/prod/values.yaml` | `nodeSelector: on-demand` (replicas stay 2) |
| VPC-CNI | `modules/eks/main.tf` | prefix delegation on (more pods/node → fewer nodes) |
| System node group | `modules/eks/main.tf` | `2× c7i-flex.large` (flex = cheaper burstable) |
| RDS | `modules/rds/main.tf` | `db.t3.micro` (free-tier eligible), `multi_az = false`, no Performance Insights / Enhanced Monitoring |

These stay as-is even on a paid plan (they're sensible cost choices), except you may want to
bump dev off spot / raise replicas if you need more stability.

---

## 3. Other Free-Plan restrictions you MIGHT still hit

If a `terraform apply` fails with `FreeTierRestrictionError` / "upgrade your account plan",
match it here:

| If the error mentions… | The fix |
|---|---|
| **RDS Multi-AZ** | already `multi_az = false` ✓ |
| **RDS instance class** | keep `db.t3.micro` (only free-tier-eligible class) |
| **RDS Provisioned IOPS / storage** | keep `gp3` (or `gp2`), `allocated_storage = 20`, no `iops` |
| **RDS Performance Insights / Enhanced Monitoring** | leave them unset (off) — they're not free |
| **EC2 instance type** | Free Plan limits some types; flex/`t3` are generally fine. If blocked, drop to a smaller allowed type |
| **NAT Gateway / EIP count** | already `single_nat_gateway = true`; if blocked, consider a NAT instance |
| **Anything else** | the blunt fix is **upgrade to a paid plan** — it clears all of these |

---

## 4. The decision

- **Short demo?** Keep patching restriction errors as they appear (each is a 1-line tweak).
- **Running 24/7?** **Upgrade to a paid plan now.** EKS isn't free regardless, the Free Plan
  will keep throwing these, and it auto-closes the account. The credits then cushion the bill
  instead of gating your config.

## 5. Revert checklist (after upgrading to paid)
- [ ] `modules/rds/main.tf`: `backup_retention_period` → `7`
- [ ] (optional) dev off spot / replicas back to 2 if you want dev HA
- [ ] (optional) Multi-AZ RDS for prod, Performance Insights, longer backups
