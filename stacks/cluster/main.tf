module "vpc" {
  source       = "../../modules/vpc"
  cluster_name = var.cluster_name
  region       = var.region
}

module "eks" {
  source              = "../../modules/eks"
  cluster_name        = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  ci_role_arn         = module.ecr.ci_role_arn
  admin_principal_arn = var.admin_principal_arn
}

module "dns_tls" {
  source      = "../../modules/dns-tls"
  domain_name = var.domain_name
}

module "alarms" {
  source       = "../../modules/alarms"
  cluster_name = var.cluster_name
  alert_email  = var.alert_email
}

module "budgets" {
  source      = "../../modules/budgets"
  alert_email = var.alert_email
}

module "backup" {
  source = "../../modules/backup"
  name   = var.cluster_name
}

module "waf_cloudfront" {
  source             = "../../modules/waf-cloudfront"
  domain_name        = var.domain_name
  origin_domain      = "origin.${var.domain_name}"
  acm_cert_arn       = module.dns_tls.acm_cert_arn
  route53_zone_id    = module.dns_tls.zone_id
  enable_dns_cutover = var.enable_cloudfront_cutover
}

module "ecr" {
  source       = "../../modules/ecr"
  cluster_name = var.cluster_name
  github_org   = var.github_org
  github_repo  = var.github_repo
}

module "addons" {
  source = "../../modules/addons"

  cluster_name                       = var.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  oidc_provider_arn                  = module.eks.oidc_provider_arn
  oidc_provider                      = module.eks.oidc_provider
  node_security_group_id             = module.eks.node_security_group_id
  vpc_id                             = module.vpc.vpc_id
  private_subnet_ids                 = module.vpc.private_subnet_ids
  region                             = var.region
  domain_name                        = var.domain_name
  route53_zone_id                    = module.dns_tls.zone_id

  depends_on = [module.eks]
}
