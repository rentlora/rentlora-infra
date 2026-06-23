output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "oidc_provider" { value = module.eks.oidc_provider }
output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "db_subnet_group_name" { value = module.vpc.db_subnet_group_name }
output "ecr_repo_urls" { value = module.ecr.repo_urls }
output "ecr_registry" { value = module.ecr.registry }
output "ci_role_arn" { value = module.ecr.ci_role_arn }         # infra repo → AWS_CI_ROLE_ARN
output "ci_app_role_arn" { value = module.ecr.ci_app_role_arn } # app repo  → AWS_CI_ROLE_ARN
output "acm_cert_arn" { value = module.dns_tls.acm_cert_arn }
output "route53_zone_id" { value = module.dns_tls.zone_id }
output "route53_name_servers" { value = module.dns_tls.zone_name_servers }
output "karpenter_node_role_arn" { value = module.addons.karpenter_node_role_arn }
output "karpenter_node_instance_profile" { value = module.addons.karpenter_node_instance_profile }
