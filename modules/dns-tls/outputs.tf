output "zone_id" { value = aws_route53_zone.main.zone_id }
output "zone_name_servers" { value = aws_route53_zone.main.name_servers }
output "acm_cert_arn" { value = aws_acm_certificate_validation.wildcard.certificate_arn }
