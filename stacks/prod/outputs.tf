output "rds_endpoint" { value = module.rds.db_endpoint }
output "property_sync_queue_url" { value = module.sqs.property_sync_queue_url }
output "booking_events_queue_url" { value = module.sqs.booking_events_queue_url }
output "images_bucket_name" { value = module.s3_cdn.bucket_name }
output "cdn_domain" { value = module.s3_cdn.cdn_domain }
output "irsa_role_arns" { value = module.iam_irsa.role_arns }
output "jwt_secret_arn" { value = module.ssm_secrets.jwt_secret_arn }
