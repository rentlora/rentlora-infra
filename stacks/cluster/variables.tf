# Configuration is supplied via terraform.tfvars (no hardcoded defaults).
variable "region" {
  type        = string
  description = "AWS region for all resources."
}
variable "cluster_name" {
  type        = string
  description = "EKS cluster name; also used for discovery tags and resource naming."
}
variable "domain_name" {
  type        = string
  description = "Public domain managed in Route53 (ACM cert + external-dns)."
}
variable "github_org" {
  type        = string
  description = "GitHub org that owns the repos (used for the OIDC trust subject)."
}
variable "github_repo" {
  type        = string
  description = "Primary GitHub repo name."
}
variable "alert_email" {
  type        = string
  description = "Email that receives CloudWatch alarm notifications (must be confirmed after apply)."
}
