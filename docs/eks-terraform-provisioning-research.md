# EKS cluster provisioning via Terraform — research

Resolves [#33](https://github.com/Dulain-Willis/steam-infra/issues/33), part of map [#27](https://github.com/Dulain-Willis/steam-infra/issues/27).

Scope per [#28](https://github.com/Dulain-Willis/steam-infra/issues/28): Terraform provisions the EKS
cluster + Strimzi operator install. Kafka Connect connector CRDs are applied via kubectl separately —
out of scope here.

## What's already in `terraform/`

- Local state (`.tfstate` gitignored, no remote backend) — single-operator, single-machine project.
- One VPC (`aws_vpc.main`, `10.0.0.0/16`), one AZ-a public `/24` (`10.0.0.0/24`, IGW, NAT-less — bastion
  and generator EC2s live here with public IPs), and two private `/24`s across `us-east-1a`/`us-east-1b`
  (`10.0.1.0/24`, `10.0.2.0/24`) used only as the RDS subnet group. **No NAT gateway exists** — the
  private subnets have no route to the internet today.
- Security groups are per-workload (`bastion`, `generator`, `rds`) with narrow `aws_security_group_rule`
  ingress added after the fact (e.g. `rds_from_bastion`, `rds_from_generator` by source SG, not CIDR).
  Everything egresses `0.0.0.0/0`.
- Everything is flat resources in `network.tf` / `rds.tf` / `bastion.tf` / `generator.tf` — no modules
  used anywhere yet. Provider pinned `hashicorp/aws ~> 5.0`, OpenTofu `>= 1.12`.
- `skip_final_snapshot = true`, `deletion_protection = false` on RDS — teardown is a first-class,
  frequent operation (`tofu destroy` between sessions), not an edge case.

## 1. Module vs hand-rolled

Use **`terraform-aws-modules/eks/aws`** (the de facto standard; the AWS EKS docs' own Terraform
walkthrough anchors on it). Hand-rolling `aws_eks_cluster` + `aws_eks_node_group` + all the IAM
documents is a lot of boilerplate for zero benefit at this project's scale, and the module is what
almost every current tutorial/blueprint (including AWS's own "EKS Blueprints for Terraform") builds on.
Latest major is v21 (registry, published 2026) — it dropped the old `manage_aws_auth` /
`aws-auth` ConfigMap pattern in favor of native EKS access entries (`access_entries` block), which
matters because it changes how you'd grant your own IAM user cluster-admin.

What the module handles for you:
- Control plane (`aws_eks_cluster`) + the cluster IAM role/policy attachments.
- Node group IAM roles + instance profiles + required policy attachments
  (`AmazonEKSWorkerNodePolicy`, CNI, ECR read-only) via its `eks-managed-node-group` submodule.
- Cluster security group + node security group with the control-plane↔node rules already wired
  (the fiddly part if hand-rolled — cluster API↔kubelet, node↔node, CoreDNS, etc.).
- EKS-managed **addons** (`cluster_addons` block: vpc-cni, coredns, kube-proxy, and now
  `eks-pod-identity-agent`) as first-class `aws_eks_addon` resources instead of whatever came
  baked into the AMI.
- KMS encryption for secrets, OIDC provider for IRSA, CloudWatch log group for control-plane logs —
  all opt-in blocks.

What you still wire up yourself (not in scope for the module):
- The Strimzi operator install itself — that's a `helm_release` resource (Helm provider) referencing
  the `strimzi/strimzi-kafka-operator` chart, separate from the EKS module.
- `kubernetes`/`helm` provider auth against the new cluster (needs `aws eks get-token` /
  `aws_eks_cluster_auth` data source wiring — a well-known chicken-and-egg problem when cluster and
  workloads are applied in the same `tofu apply`; see teardown section below).
- Any IAM Roles for Service Accounts (IRSA) / pod identity association for workloads that need AWS API
  access (e.g. a future sink connector writing to S3) — the module creates the OIDC provider but you
  still write the per-workload role.
- Ingress/LoadBalancer controller (AWS Load Balancer Controller) if anything needs external access —
  not needed for this ticket's scope (Strimzi + Connect are internal-only).

Sources:
- [terraform-aws-modules/eks/aws — Terraform Registry](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [terraform-aws-modules/terraform-aws-eks — GitHub](https://github.com/terraform-aws-modules/terraform-aws-eks)
- [eks-managed-node-group submodule](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest/examples/eks-managed-node-group)

## 2. Reuse the existing VPC, or a new one?

**Reuse the existing VPC** (`aws_vpc.main`), but the current subnets need changes before EKS goes in
them — they're too small and one is missing a route to the internet:

- **Subnet size is the real blocker.** The private subnets are `/24`s (251 usable IPs). AWS's own VPC
  CNI guidance says to size node subnets for 3–5x expected max pod count because each node reserves a
  block of IPs per ENI up front, not just what's running. A `t3.medium` caps at 17 pods; with the
  default CNI (no prefix delegation) a `/24` comfortably fits only a handful of small nodes. For a
  cluster this small (see sizing below) a `/24` is *workable* but tight — recommend adding two new
  `/24`s (or resizing to `/23`s) dedicated to EKS nodes rather than dropping node ENIs into the RDS
  subnet group's subnets, so RDS's subnet group and its assumptions (only DB instances present) stay
  undisturbed. Enabling **VPC CNI prefix delegation** (`ENABLE_PREFIX_DELEGATION=true` on the
  `vpc-cni` addon config) is the cheaper fix if you'd rather not touch subnets — it hands out /28s per
  ENI instead of individual IPs, multiplying effective capacity in the same `/24`s.
- **No NAT gateway exists today.** Nodes in a private subnet need outbound internet (to pull
  `registry.k8s.io` images, hit the EKS API, pull the Strimzi/Kafka images from Docker Hub/quay.io)
  unless everything is mirrored through VPC endpoints. Today's private subnets have zero egress route.
  Either add a NAT gateway (adds a small hourly + per-GB cost — worth flagging since this project is
  cost-conscious) or put the node group in the **public** subnet with `map_public_ip_on_launch` (fine
  for a learning cluster, avoids NAT cost, matches how bastion/generator already work) with a tight
  security group. Given the project already runs bastion/generator with public IPs + SSM instead of
  paying for NAT, putting nodes in the public subnet is the more consistent, cheaper choice here —
  the EKS module supports mixing (control plane needs subnets in ≥2 AZs; nodes can be public).
- **AZ count**: EKS requires the control plane to span at least 2 AZs. The existing VPC already has
  `us-east-1a`/`us-east-1b` private subnets and one `us-east-1a` public subnet — add a second public
  subnet in `us-east-1b` (or pass the two existing private subnets plus a new public one) to satisfy
  this without adding a third AZ.
- **Security groups**: EKS nodes need a **new security group** (the module creates one) — reusing
  `aws_security_group.rds` is wrong (mixes concerns and the RDS SG has no relevant rules). The
  RDS SG needs one **new ingress rule** from the EKS node security group on 5432, alongside the
  existing `rds_from_bastion`/`rds_from_generator` rules, so Debezium's source connector inside EKS can
  reach Postgres. This is additive — no changes needed to the two existing RDS ingress rules.
- Net: same VPC, same account, no case for a second VPC (no peering/isolation requirement exists) —
  just extend `network.tf` with EKS-sized subnets and let the EKS module manage its own SG.

Sources:
- [Amazon EKS networking / VPC requirements — AWS docs](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html)
- [Addressing IPv4 exhaustion in EKS clusters — AWS blog](https://aws.amazon.com/blogs/containers/addressing-ipv4-address-exhaustion-in-amazon-eks-clusters-using-private-nat-gateways/)
- [Reserving minimum IPs / VPC CNI prefix delegation — Devtron](https://devtron.ai/blog/reserving-minimum-ips-in-eks-cluster/)

## 3. Node group config for a small, torn-down-often cluster

**Managed node group, one Spot capacity type, small instance pool** — not Fargate, not self-managed.

- **Managed node group over Fargate**: Strimzi runs Kafka brokers as StatefulSets needing persistent
  local-ish behavior and the Kafka/Connect images are heavier; Fargate has per-pod overhead, no
  DaemonSet support (Strimzi's entity operator / metrics setups sometimes assume node-level access),
  and is typically *more* expensive per running vCPU than a small Spot EC2 fleet for anything running
  close to 24/7 during a session. Managed node group over self-managed: AWS handles AMI patching,
  drain-on-terminate, and lifecycle — no reason to hand-roll launch templates for a learning project.
- **Capacity type: `SPOT`.** This is a personal/learning cluster torn down between sessions, not
  production — spot interruption risk (2-minute notice, reclaimable anytime) is an acceptable
  tradeoff for the ~70-90% discount vs on-demand. Specify **multiple instance types** in the node
  group (e.g. `t3.medium`, `t3a.medium`, `t3.large`) so EKS can pick across several Spot pools —
  single-instance-type spot requests fail capacity more often.
- **Sizing**: start with `desired_size = 2`, `min_size = 1`, `max_size = 3`, instance types
  `["t3.medium", "t3a.medium"]`. Strimzi's cluster operator + a minimal single-broker Kafka + Kafka
  Connect + entity operator fits in 2 nodes at this size; bump to `t3.large` if Kafka Connect worker
  memory (Connect defaults to a 256MB-1GB heap per worker, more with Debezium's own buffering) proves
  the medium too small. Since the whole cluster is destroyed and recreated per session anyway, don't
  over-engineer autoscaling (Cluster Autoscaler/Karpenter) — a fixed small node group with generous
  `max_size` headroom is enough; add real autoscaling only if node capacity actually becomes a
  bottleneck during a session.

Sources:
- [Cost optimization and resilience for EKS with Spot Instances — AWS blog](https://aws.amazon.com/blogs/compute/cost-optimization-and-resilience-eks-with-spot-instances/)
- [Managed node groups with EC2 Spot — eksctl docs](https://docs.aws.amazon.com/eks/latest/eksctl/spot-instances.html)

## 4. `tofu destroy` gotchas

`tofu destroy` does **not** cleanly tear down everything an EKS cluster accumulates once workloads
have run on it, for reasons outside Terraform's own state:

- **LoadBalancers created by Kubernetes Services (`type: LoadBalancer`) or Ingress are not tracked in
  Terraform state at all** — a Service's controller (AWS cloud-provider or ALB controller) creates the
  ELB/NLB directly via the AWS API. `terraform destroy` on the cluster/VPC has nothing to delete, but
  the leftover ELB holds an ENI in the subnet, which blocks subnet/VPC/SG deletion with a
  `DependencyViolation`. **This project's current scope doesn't create any LoadBalancer-typed Services**
  (Strimzi + Connect are internal, Kafka Connect connector configs are explicitly out of scope for
  Terraform) — so this specific failure mode shouldn't hit *this* ticket's resources, but it's the
  #1 documented EKS-teardown gotcha and worth guarding against if anything with an Ingress/LB gets
  added later.
- **Orphaned ENIs from the VPC CNI**: nodes/pods can leave "available"-status ENIs behind after node
  group termination, which block security-group and subnet deletion the same way. This is a
  known upstream flakiness in `terraform-aws-modules/terraform-aws-eks` and the AWS VPC CNI, not
  something a Terraform config can fully prevent — the practical mitigation is destroy-time ordering
  (destroy node group / workloads *before* the cluster / VPC / SGs) plus, if it still gets stuck, a
  manual `aws ec2 delete-network-interface` and re-run `tofu destroy`.
- **Helm-provisioned Strimzi operator ordering**: if Strimzi is installed via `helm_release` in the
  same `tofu apply` as the cluster, `terraform destroy` will try to uninstall the Helm release, which
  needs a live, authenticated connection to the cluster's Kubernetes API — but if the node group or
  cluster is destroyed out of order (or the `kubernetes`/`helm` provider's auth token has expired,
  since EKS tokens are short-lived), the helm/kubernetes provider calls fail and destroy has to be
  re-run or resources force-removed from state. Mitigate by giving Terraform explicit
  `depends_on` from the Helm release to the node group (not just the cluster) so destroy order is
  node-group-still-up → helm uninstall → cluster teardown, and using
  `data.aws_eks_cluster_auth` (regenerated per-run, not a cached token) for the kubernetes/helm
  provider blocks.
- **Practical recommendation for this project**: keep the Strimzi Helm release itself simple (no
  Ingress/LoadBalancer Services in the chart values — Strimzi listeners default to internal
  `ClusterIP`/headless services, which is what CDC-to-Kafka-Connect-in-cluster needs anyway), and
  don't add anything that provisions an ELB until there's an actual external-access requirement. That
  keeps this ticket's `tofu destroy` clean by construction rather than needing cleanup scripting.
  If an Ingress/LB does get added later, budget for a pre-destroy step (`kubectl delete svc -A
  --field-selector spec.type=LoadBalancer` or equivalent) before `tofu destroy`.

Sources:
- [Elastic Load Balancer created outside Terraform not deleted on destroy — hashicorp/terraform-provider-aws #21863](https://github.com/hashicorp/terraform-provider-aws/issues/21863)
- [Destroying EKS with Terraform does not delete NLB — kubernetes/kubernetes #93390](https://github.com/kubernetes/kubernetes/issues/93390)
- [Unreliable ENI destroy — terraform-aws-modules/terraform-aws-eks #1267](https://github.com/terraform-aws-modules/terraform-aws-eks/issues/1267)
- [Troubleshooting unreliable ENI destroy on EKS — HashiCorp Discuss](https://discuss.hashicorp.com/t/troubleshooting-unreliable-eni-destroy-aws-eks/22757)
- [terraform destroy of helm_release resources — hashicorp/terraform-provider-helm #593](https://github.com/hashicorp/terraform-provider-helm/issues/593)
- [EKS Blueprints for Terraform FAQ / known destroy issues](https://aws-ia.github.io/terraform-aws-eks-blueprints/faq/)

## Recommendation summary

- Use `terraform-aws-modules/eks/aws` (v21.x), one managed node group, `capacity_type = "SPOT"`,
  multiple `t3.medium`/`t3a.medium` instance types, `desired_size = 2`.
- Same VPC as RDS. Add a second public subnet (`us-east-1b`) for the 2-AZ control-plane requirement,
  and either resize/add subnets for node capacity or turn on VPC CNI prefix delegation. Put nodes in
  the public subnets (matches the existing no-NAT, SSM-managed bastion/generator pattern) rather than
  paying for a NAT gateway.
- New EKS-node security group (module-managed) + one new ingress rule on the existing RDS SG allowing
  5432 from it.
- Strimzi operator via `helm_release`, `depends_on` the node group, no LoadBalancer-typed Services in
  scope — keeps `tofu destroy` clean without extra cleanup scripting for this ticket. ENI/ELB orphan
  issues are a known EKS-wide gotcha to watch for once anything external-facing is added later.
