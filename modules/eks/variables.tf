variable "cluster_name" { type = string }
variable "cluster_version" {
  type    = string
  default = "1.32"
}
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

# CI role (rentlora-eks-ci) granted read access so GitHub Actions can run
# `kubectl rollout status` during deploy verification.
variable "ci_role_arn" { type = string }
