variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_certificate_authority_data" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider" { type = string }
variable "node_security_group_id" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "domain_name" {
  type    = string
  default = "rentlora.in"
}
variable "route53_zone_id" { type = string }
