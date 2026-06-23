output "repo_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "ci_role_arn" { value = aws_iam_role.ci.arn }         # infra role (cluster-admin)
output "ci_app_role_arn" { value = aws_iam_role.ci_app.arn } # app role (ECR push only)
