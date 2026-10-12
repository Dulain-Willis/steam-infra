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
    # Everything that isn't a Kafka broker, including *both* Airflow releases
    # (the kafka pool below is tainted, so nothing else can land there).
    #
    # desired_size is 3 rather than 2 because of the VPC-CNI pod ceiling, not
    # memory. t3.medium allows 17 pods per node, and three DaemonSets
    # (aws-node, ebs-csi-node, kube-proxy) take one slot each on every node,
    # so each node contributes 14 usable slots. Measured on a live cluster
    # with one Airflow release: 28 of 34 slots used, 6 free — and a second
    # Airflow release is 8 pods (api-server, dag-processor, scheduler,
    # triggerer, worker, statsd, postgresql, redis). It would not schedule;
    # the pods would sit Pending with `Too many pods` and there is no
    # autoscaler anywhere in this repo to add a node. A third node takes it to
    # 51 slots with ~20 free.
    #
    # Memory is not the constraint and adding requests would not help: only
    # one container in the whole airflow namespace sets a memory request, and
    # the two nodes were at 31% and 12% of allocatable when they were full on
    # pod count. **So re-check pod slots, not memory, before adding a third
    # environment** — `kubectl get nodes -o custom-columns=
    # 'NAME:.metadata.name,MAXPODS:.status.allocatable.pods'` against the
    # per-node pod counts.
    system = {
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 3
      desired_size = 3
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

# Same IRSA pattern as ebs_csi_irsa above, for the AWS Load Balancer
# Controller (#107). Unlike aws-ebs-csi-driver, AWS doesn't offer this as an
# EKS-managed cluster_addon (#106's "same addon pattern" decision doesn't
# hold up against the real API) — so only the IRSA role lives here; the
# controller workload itself is an ArgoCD Application
# (argocd/apps/alb-controller.yaml), matching ADR 0001's boundary
# (Terraform = AWS/EKS only, ArgoCD = everything k8s-application-layer).
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
