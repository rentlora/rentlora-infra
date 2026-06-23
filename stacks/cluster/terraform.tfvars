region       = "us-east-1"
cluster_name = "rentlora-eks"
domain_name  = "rentlora.in"
github_org   = "rentlora"
github_repo  = "rentlora"
alert_email  = "iyas2458@gmail.com"
# rentlora.in -> CloudFront (WAF + edge cache). Verified the distribution serves
# the app via its *.cloudfront.net name before flipping this on.
enable_cloudfront_cutover = true
