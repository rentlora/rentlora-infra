locals {
  services = [
    "frontend",
    "property-service",
    "booking-service",
    "ai-service",
    "admin-service",
    "ai-search-service",
    "user-service",
  ]

  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/rentlora-ci-boundary"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "rentlora-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ─── GitHub Actions OIDC + CI role ──────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ─── Permission boundary ─────────────────────────────────────────────────────
# Prevents privilege escalation from a compromised pipeline:
#   - CI role can do anything needed for terraform plan/apply
#   - CI role CANNOT create IAM users (no backdoor static credentials)
#   - CI role CANNOT create IAM roles without the same boundary applied
#     (so any role it creates is equally constrained)
#   - CI role CANNOT remove its own boundary or another role's boundary
resource "aws_iam_policy" "ci_boundary" {
  name        = "rentlora-ci-boundary"
  description = "Permission boundary for rentlora-eks-ci - prevents IAM privilege escalation"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowAllServices"
        Effect   = "Allow"
        Action   = ["*"]
        Resource = "*"
      },
      {
        # Block creating IAM users — prevents backdoor static credentials
        Sid    = "DenyIAMUsers"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateAccessKey",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
          "iam:CreateLoginProfile"
        ]
        Resource = "*"
      },
      {
        # Block creating roles WITHOUT the same boundary — prevents escape hatch
        Sid      = "DenyCreateRoleWithoutBoundary"
        Effect   = "Deny"
        Action   = ["iam:CreateRole"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "iam:PermissionsBoundary" = local.boundary_arn
          }
        }
      },
      {
        # Block removing or replacing the boundary on any role
        Sid    = "DenyBoundaryModification"
        Effect = "Deny"
        Action = [
          "iam:DeleteRolePermissionsBoundary",
          "iam:PutRolePermissionsBoundary"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "iam:PermissionsBoundary" = local.boundary_arn
          }
        }
      }
    ]
  })
}

# ─── INFRA role ──────────────────────────────────────────────────────────────
# Used ONLY by the rentlora-infra repo's terraform pipeline. Has broad AWS access
# (AdministratorAccess) + EKS cluster-admin (granted in modules/eks) because
# terraform must manage every resource and every Helm release in the cluster.
# Trust is scoped to the infra repo only — the app repo cannot assume this.
resource "aws_iam_role" "ci" {
  name                 = "${var.cluster_name}-ci"
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          # Infra repo ONLY — the high-privilege role is not reachable from the
          # high-churn app repo.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.infra_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# AdministratorAccess + boundary = full terraform access, no privilege escalation
resource "aws_iam_role_policy_attachment" "ci_admin" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "ci" {
  name = "ci-policy"
  role = aws_iam_role.ci.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [for r in aws_ecr_repository.services : r.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::rentlora-terraform-state/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::rentlora-terraform-state"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/rentlora-terraform-locks"
      }
    ]
  })
}

# ─── APP role ────────────────────────────────────────────────────────────────
# Used ONLY by the rentlora application repo's build pipeline. The app flow is
# pure GitOps: build image -> push to ECR -> bump the tag in rentlora-helm ->
# ArgoCD deploys. So this role needs ECR push and NOTHING else — no AWS admin,
# no Terraform state, and no Kubernetes access at all (it has no EKS access
# entry). A compromised app build can push an image; it cannot touch the cluster
# or read secrets. Trust is scoped to the app repo only.
resource "aws_iam_role" "ci_app" {
  name                 = "${var.cluster_name}-ci-app"
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci_app" {
  name = "ci-app-ecr-push"
  role = aws_iam_role.ci_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [for r in aws_ecr_repository.services : r.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:DescribeImages",
          "ecr:DescribeImageScanFindings"
        ]
        Resource = [for r in aws_ecr_repository.services : r.arn]
      }
    ]
  })
}
