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
