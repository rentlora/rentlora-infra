resource "random_password" "jwt_secret" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "/rentlora/${var.env}/jwt-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id = aws_secretsmanager_secret.jwt_secret.id
  # Stored as the raw value (not JSON) — services read SecretString directly.
  secret_string = random_password.jwt_secret.result
}

locals {
  # Key names must match exactly what the services read in their config.py.
  params = {
    "db-endpoint"                = var.db_endpoint
    "db-user"                    = "postgres"
    "db-name"                    = "rentlora"
    "aws-region"                 = var.region
    "s3-image-bucket"            = var.s3_bucket_name
    "cloudfront-domain"          = var.cdn_domain
    "property-sync-queue-url"    = var.property_sync_queue_url
    "booking-events-queue-url"   = var.booking_events_queue_url
    "ses-sender-email"           = var.ses_sender_email
    "bedrock-nova-model-id"      = "amazon.nova-lite-v1:0"
    "bedrock-embedding-model-id" = "amazon.titan-embed-text-v2:0"
    "ai-search-service-url"      = "http://ai-search-service.${var.namespace}.svc.cluster.local:8005"
    "booking-service-url"        = "http://booking-service.${var.namespace}.svc.cluster.local:8002"
  }
}

resource "aws_ssm_parameter" "params" {
  for_each = local.params

  name  = "/rentlora/${var.env}/${each.key}"
  type  = "String"
  value = each.value

  lifecycle {
    ignore_changes = [value] # allow out-of-band updates without Terraform drift
  }
}
