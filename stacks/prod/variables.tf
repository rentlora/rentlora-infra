# Configuration is supplied via terraform.tfvars.
variable "region" {
  type        = string
  description = "AWS region."
}
variable "env" {
  type        = string
  description = "Environment short name (e.g. prod)."
}
variable "namespace" {
  type        = string
  description = "Kubernetes namespace for this environment."
}
variable "deletion_protection" {
  type        = bool
  description = "RDS deletion protection."
}
variable "skip_final_snapshot" {
  type        = bool
  description = "Skip the RDS final snapshot on destroy."
}
