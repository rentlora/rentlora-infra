variable "env" { type = string }
variable "namespace" { type = string }
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "db_endpoint" { type = string }
variable "property_sync_queue_url" { type = string }
variable "booking_events_queue_url" { type = string }
variable "s3_bucket_name" { type = string }
variable "cdn_domain" { type = string }
variable "ses_sender_email" {
  type    = string
  default = "noreply@rentlora.in"
}
