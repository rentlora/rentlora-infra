output "db_endpoint" { value = aws_db_instance.postgres.endpoint }
output "db_secret_arn" { value = aws_secretsmanager_secret.db_password.arn }
output "db_password" {
  value     = random_password.db.result
  sensitive = true
}
