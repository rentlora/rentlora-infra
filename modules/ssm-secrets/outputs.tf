output "jwt_secret_arn" { value = aws_secretsmanager_secret.jwt_secret.arn }
output "ssm_path_prefix" { value = "/rentlora/${var.env}" }
