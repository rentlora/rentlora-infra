output "bucket_name" { value = aws_s3_bucket.images.id }
output "cdn_domain" { value = aws_cloudfront_distribution.images.domain_name }
