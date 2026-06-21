locals {
  oidc_host = replace(var.oidc_provider, "https://", "")

  # Common allow statements added to every service role
  common_statements = [
    {
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.secrets_path_arn
    },
    {
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
      Resource = var.ssm_path_arn
    }
  ]
}

# ─── Factory: one IRSA role per service ─────────────────────────────────────

resource "aws_iam_role" "service" {
  for_each = local.service_configs

  name = "${var.cluster_name}-${var.env}-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${var.namespace}:${each.key}"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "service" {
  for_each = local.service_configs

  name = "policy"
  role = aws_iam_role.service[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(each.value.statements, local.common_statements)
  })
}

locals {
  service_configs = {
    "property-service" = {
      statements = [
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
          Resource = var.property_sync_queue_arn
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
          Resource = "${var.images_bucket_arn}/*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = var.images_bucket_arn
        }
      ]
    }

    "ai-search-service" = {
      statements = [
        {
          Effect   = "Allow"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
          Resource = var.property_sync_queue_arn
        },
        {
          Effect = "Allow"
          Action = ["bedrock:InvokeModel"]
          # Titan to embed the query + Nova to summarize/rank the results.
          Resource = [
            "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0",
            "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0"
          ]
        }
      ]
    }

    "booking-service" = {
      statements = [
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
          Resource = var.booking_events_queue_arn
        },
        {
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = "*"
        }
      ]
    }

    "ai-service" = {
      statements = [{
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
          "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0"
        ]
      }]
    }

    "admin-service" = {
      statements = [] # DB only; common_statements cover secrets + SSM
    }

    "user-service" = {
      statements = [
        {
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail"]
          Resource = "*"
        }
      ]
    }
  }
}
