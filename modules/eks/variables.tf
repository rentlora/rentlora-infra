variable "cluster_name" { type = string }
variable "cluster_version" {
  type    = string
  default = "1.32"
}
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

# CI role (rentlora-eks-ci) granted cluster-admin so the pipeline can manage
# Helm releases / cluster-scoped objects via terraform.
variable "ci_role_arn" { type = string }

# Human operator IAM principal (e.g. the IAM user running kubectl). Gets an
# explicit cluster-admin access entry so access never depends on who applied.
variable "admin_principal_arn" { type = string }
