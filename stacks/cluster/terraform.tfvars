region       = "us-east-1"
cluster_name = "rentlora-eks"
domain_name  = "rentlora.in"
github_org   = "rentlora"
github_repo  = "rentlora"
alert_email  = "iyas2458@gmail.com"
# rentlora.in -> CloudFront (WAF + edge cache). Two-phase rollout:
#   1. Apply with this = false  -> distribution is created, DNS untouched.
#   2. Verify the app via the distribution's *.cloudfront.net name.
#   3. Flip to true and apply    -> repoints rentlora.in at CloudFront.
enable_cloudfront_cutover = false
