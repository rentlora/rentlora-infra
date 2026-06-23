# Origin lockdown — closes the origin.rentlora.in bypass.
#
# Without this, the prod NLB's frontend SG allows 0.0.0.0/0 on 80/443, so anyone
# could hit origin.rentlora.in directly and skip CloudFront + WAF. We instead hand
# the AWS Load Balancer Controller our OWN frontend SG (referenced from the
# gateway-prod GatewayParameters annotation) that only admits CloudFront's
# origin-facing IP ranges (an AWS-managed prefix list). All non-CloudFront traffic
# to the prod NLB is then dropped at the network layer.

data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "prod_cf_origin" {
  name        = "${var.cluster_name}-prod-cf-origin"
  description = "Prod NLB inbound: CloudFront origin-facing ranges only"
  vpc_id      = module.vpc.vpc_id
}

# CloudFront talks to the origin HTTPS-only (origin_protocol_policy = https-only),
# so a single 443 rule is all that's needed. (A managed prefix list counts as its
# max-entries toward the 60-rule SG limit, so we reference it just once.)
resource "aws_vpc_security_group_ingress_rule" "cf_https" {
  security_group_id = aws_security_group.prod_cf_origin.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
  description       = "HTTPS from CloudFront origin-facing ranges"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.prod_cf_origin.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow NLB to reach backend nodes"
}

output "prod_cf_origin_sg_id" {
  description = "Attach to the prod gateway NLB via the aws-load-balancer-security-groups annotation."
  value       = aws_security_group.prod_cf_origin.id
}
