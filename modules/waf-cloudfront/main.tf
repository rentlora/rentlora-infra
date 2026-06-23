# CloudFront in front of the prod app (origin = the NLB via origin_domain), with a
# WAFv2 WebACL attached. Static frontend is cached at the edge; /api/* is pass-through
# (no cache, forwards cookies/auth/query). DNS cutover is gated behind enable_dns_cutover
# so the distribution can be created + verified before rentlora.in is repointed.
#
# NOTE: must be applied from a us-east-1 provider — WAF scope=CLOUDFRONT and the
# CloudFront ACM cert both live in us-east-1.

# Managed policies (no need to hand-roll cache keys).
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_origin_request_policy" "all_viewer" { name = "Managed-AllViewer" }

locals {
  managed_rules = [
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesSQLiRuleSet",
    "AWSManagedRulesAmazonIpReputationList",
  ]
}

resource "aws_wafv2_web_acl" "cf" {
  name  = "rentlora-cloudfront"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Per-IP rate limit (priority 0, runs first).
  rule {
    name     = "rate-limit"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed rule groups (common, bad inputs, SQLi, IP reputation).
  dynamic "rule" {
    for_each = { for i, n in local.managed_rules : n => i }
    content {
      name     = rule.key
      priority = rule.value + 1
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "rentlora-cloudfront"
    sampled_requests_enabled   = true
  }
}

# WAF logging — so you can see what got blocked/allowed, not just counts.
# CLOUDFRONT-scope WAF logs must go to a us-east-1 log group whose name starts
# with the reserved "aws-waf-logs-" prefix.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-rentlora-cloudfront"
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "cf" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.cf.arn
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "rentlora prod — WAF + frontend edge cache"
  aliases         = [var.domain_name]
  web_acl_id      = aws_wafv2_web_acl.cf.arn
  # NA + Europe edge locations only — cheaper than the global default (All).
  price_class = "PriceClass_100"

  origin {
    domain_name = var.origin_domain
    origin_id   = "nlb"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Frontend (catch-all): cached at the edge.
  default_cache_behavior {
    target_origin_id       = "nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  # API: never cached; forward cookies/auth/query through to the origin.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "nlb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# DNS cutover — gated. Overwrites the external-dns NLB record (which is upsert-only,
# so it won't fight back once rentlora.in leaves the gateway annotation).
resource "aws_route53_record" "apex_a" {
  count           = var.enable_dns_cutover ? 1 : 0
  zone_id         = var.route53_zone_id
  name            = var.domain_name
  type            = "A"
  allow_overwrite = true
  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_aaaa" {
  count           = var.enable_dns_cutover ? 1 : 0
  zone_id         = var.route53_zone_id
  name            = var.domain_name
  type            = "AAAA"
  allow_overwrite = true
  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}
