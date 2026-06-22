module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = true

  # EKS managed addons — AWS handles patching
  cluster_addons = {
    # Prefix delegation: each ENI hands out /28 IPv4 prefixes instead of single
    # secondary IPs, so a node can run far more pods. Lets Karpenter pack pods
    # onto fewer/smaller nodes (cost), and avoids IP exhaustion on t3.small.
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
    amazon-cloudwatch-observability = { most_recent = true }
    eks-pod-identity-agent          = { most_recent = true }
  }

  # Bootstrap node group — runs the platform layer (Karpenter, ArgoCD, kgateway,
  # external-dns, metrics-server, LB controller). NOT tainted: those addons set no
  # tolerations, so a CriticalAddonsOnly taint here would leave them (and Karpenter
  # itself) unschedulable at bootstrap — a deadlock, since no other nodes exist yet.
  # Karpenter then scales additional nodes for application pods on top of this group.
  eks_managed_node_groups = {
    system = {
      # AWS Free Tier plan only permits free-tier-eligible instance types
      # (t3.medium is refused). c7i-flex.large = 2 vCPU / 4 GiB is the chosen
      # platform node. 2 nodes = 4 vCPU, within the default 5-vCPU On-Demand
      # Standard quota; max stays at 2 so it can't exceed it. Karpenter scales
      # application nodes on top of this group.
      instance_types = ["c7i-flex.large"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      labels = {
        role = "system"
      }
    }
  }

  # Allow Karpenter nodes to join the cluster
  enable_cluster_creator_admin_permissions = true

  # Grant the GitHub Actions CI role read access to the app namespaces so the
  # deploy workflow can run `kubectl rollout status`. View policy covers
  # get/list/watch on deployments/replicasets/pods — enough for verification.
  access_entries = {
    ci = {
      principal_arn = var.ci_role_arn
      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["rentlora-dev", "production"]
          }
        }
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# IRSA role for the EBS CSI driver controller. The driver needs permission to
# create/attach/detach EBS volumes; without this its controller pods crashloop.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.oidc_provider, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(module.eks.oidc_provider, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# CloudWatch Observability addon needs IAM to publish: Fluent Bit -> CloudWatch Logs
# and the agent -> Container Insights metrics. Granted via EKS Pod Identity (the
# eks-pod-identity-agent addon is enabled) to the addon's `cloudwatch-agent` SA, so
# both the agent and Fluent Bit DaemonSets (same SA) get credentials. Without this
# the pods run but get AccessDenied. CloudWatchAgentServerPolicy covers PutMetricData
# + Create/PutLogEvents.
resource "aws_iam_role" "cloudwatch_observability" {
  name = "${var.cluster_name}-cloudwatch-observability"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_pod_identity_association" "cloudwatch_observability" {
  cluster_name    = var.cluster_name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_observability.arn
}
