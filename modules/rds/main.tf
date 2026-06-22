resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_security_group" "rds" {
  name        = "rentlora-${var.env}-rds"
  description = "Allow PostgreSQL from app nodes"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "postgres" {
  identifier        = "rentlora-${var.env}"
  engine            = "postgres"
  engine_version    = "15.7"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "rentlora"
  username = "postgres"
  password = random_password.db.result

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                  = false
  backup_retention_period   = 0 # Free Plan caps backups; 0 = no automated backups (raise after upgrading to a paid plan)
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "rentlora-${var.env}-final"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "/rentlora/${var.env}/db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  # Stored as the raw password (not JSON) — services read SecretString directly.
  secret_string = random_password.db.result
}
