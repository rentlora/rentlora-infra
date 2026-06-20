data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "rentlora-terraform-state"
    key    = "cluster/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  env       = "dev"
  namespace = "rentlora-dev"

  cluster = data.terraform_remote_state.cluster.outputs
}

module "rds" {
  source               = "../../modules/rds"
  env                  = local.env
  db_subnet_group_name = local.cluster.db_subnet_group_name
  vpc_id               = local.cluster.vpc_id
  deletion_protection  = false
  skip_final_snapshot  = true
}

module "sqs" {
  source = "../../modules/sqs"
  env    = local.env
}

module "s3_cdn" {
  source = "../../modules/s3-cdn"
  env    = local.env
}

module "ssm_secrets" {
  source                   = "../../modules/ssm-secrets"
  env                      = local.env
  namespace                = local.namespace
  db_endpoint              = module.rds.db_endpoint
  property_sync_queue_url  = module.sqs.property_sync_queue_url
  booking_events_queue_url = module.sqs.booking_events_queue_url
  s3_bucket_name           = module.s3_cdn.bucket_name
  cdn_domain               = module.s3_cdn.cdn_domain
}

module "iam_irsa" {
  source                   = "../../modules/iam-irsa"
  cluster_name             = local.cluster.cluster_name
  env                      = local.env
  namespace                = local.namespace
  oidc_provider_arn        = local.cluster.oidc_provider_arn
  oidc_provider            = local.cluster.oidc_provider
  property_sync_queue_arn  = module.sqs.property_sync_queue_arn
  booking_events_queue_arn = module.sqs.booking_events_queue_arn
  images_bucket_arn        = "arn:aws:s3:::${module.s3_cdn.bucket_name}"
  secrets_path_arn         = "arn:aws:secretsmanager:*:*:secret:/rentlora/${local.env}/*"
  ssm_path_arn             = "arn:aws:ssm:*:*:parameter/rentlora/${local.env}/*"
}
