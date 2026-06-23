variable "domain_name" {
  description = "Public domain served by CloudFront (e.g. rentlora.in)."
  type        = string
}

variable "origin_domain" {
  description = "Hostname that resolves to the prod NLB (CloudFront origin), e.g. origin.rentlora.in."
  type        = string
}

variable "acm_cert_arn" {
  description = "ACM cert in us-east-1 covering domain_name (the *.rentlora.in wildcard)."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 zone for the apex record."
  type        = string
}

variable "rate_limit" {
  description = "Max requests per 5 min per IP before WAF blocks."
  type        = number
  default     = 2000
}

variable "enable_dns_cutover" {
  description = "When true, point domain_name at CloudFront. Keep false until the distribution is Deployed + verified via its *.cloudfront.net name."
  type        = bool
  default     = false
}
