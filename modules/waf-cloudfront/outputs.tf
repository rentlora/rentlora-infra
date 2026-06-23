output "distribution_domain" {
  description = "CloudFront *.cloudfront.net name — test the app here before DNS cutover."
  value       = aws_cloudfront_distribution.app.domain_name
}

output "distribution_id" {
  value = aws_cloudfront_distribution.app.id
}

output "web_acl_arn" {
  value = aws_wafv2_web_acl.cf.arn
}
