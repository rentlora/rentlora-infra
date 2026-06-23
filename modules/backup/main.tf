# Central AWS Backup plan — daily backups of every resource tagged
# backup-plan=<selection_tag_value> (the dev + prod RDS instances). This is
# defense-in-depth on top of RDS automated backups: a separate vault, longer
# retention, and a single place to add cross-region copy or EBS later.

resource "aws_backup_vault" "main" {
  name = "${var.name}-vault"
}

resource "aws_backup_plan" "main" {
  name = "${var.name}-daily"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 * * ? *)" # 05:00 UTC daily
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.delete_after_days
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "main" {
  name         = "${var.name}-selection"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.main.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "backup-plan"
    value = var.selection_tag_value
  }
}
