# EKS cluster for the CDC pipeline (Strimzi/Kafka Connect land on this later,
# per #40+). Nodes sit in the 2 dedicated public subnets above — no NAT
# gateway per the cost/complexity tradeoff locked in #33, so public IPs are
# the only way these nodes reach the internet (image pulls, etc).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "steam-infra"
  cluster_version = "1.31"

  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.eks_a.id, aws_subnet.eks_b.id]

  cluster_endpoint_public_access = true

  # API-only auth mode + creator admin permissions avoids needing the
  # kubernetes/helm providers just to manage aws-auth.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Needed so the EBS CSI driver addon below can assume an IAM role via a
  # k8s service account (Airflow's Postgres/Redis PVCs need this to bind).
  enable_irsa = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }

    # Dedicated pool for Kafka brokers, tainted so only workloads that
    # explicitly tolerate it land here (per #37).
    kafka = {
      instance_types = ["m5.large"]
      capacity_type  = "ON_DEMAND"

      min_size     = 3
      max_size     = 3
      desired_size = 3

      labels = {
        role = "kafka"
      }

      taints = {
        kafka = {
          key    = "dedicated"
          value  = "kafka"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = {
    Name = "steam-infra"
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
