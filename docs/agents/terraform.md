# Terraform: targeted applies

This stack is torn down between sessions (cost discipline) and brought back
up with `tofu apply`, often targeting a subset of resources instead of the
whole stack (e.g. "just bring up EKS, skip RDS/generator") to save time.

## `-target` only pulls in resources referenced by an attribute

`-target=module.eks` (or any `-target`) pulls in resources `module.eks`
*references by attribute* (`vpc_id`, `subnet_ids`, etc) — it does **not**
pull in sibling resources that merely need to exist alongside it with no
attribute reference between them.

Concretely: `aws_subnet.eks_a` / `aws_subnet.eks_b` are referenced by
`module.eks`'s `subnet_ids`, so targeting `module.eks` creates the subnets.
But `aws_route_table_association.eks_a` / `.eks_b` (and the `aws_internet_gateway.gw`
/ `aws_route_table.public` they depend on) are **not** referenced by
anything in `module.eks` — nothing reads their IDs. Targeting `module.eks`
alone creates subnets with no route to the internet gateway, EKS nodes can't
reach the EC2/EKS control-plane APIs to join the cluster, and both node
groups fail after ~10-15 min with `NodeCreationFailure: Instances failed to
join the kubernetes cluster` (visible via `aws ec2 get-console-output`,
which shows `nodeadm` retrying `DescribeInstances` forever).

**When targeting an EKS-only apply, always include the network plumbing
explicitly:**

```
tofu apply -target=aws_internet_gateway.gw \
           -target=aws_route_table.public \
           -target=aws_route_table_association.eks_a \
           -target=aws_route_table_association.eks_b \
           -target=module.eks \
           -target=helm_release.strimzi
```

Same trap that `scripts/bootstrap.sh` already documents for
`-target=aws_instance.bastion -target=aws_db_instance.main` (silently drops
`aws_iam_role_policy_attachment.bastion_ssm` and the IGW/route table) — the
fix there was switching to `-exclude`. For an EKS-only bring-up there's no
equivalent single `-exclude` (excluding RDS/bastion/generator still leaves
the same missing-attribute-reference gap for the EKS subnets), so list the
network resources out explicitly instead.

If a targeted apply's node groups fail this way, don't just retry the same
target list — it repeats the ~10-15 min failure. Add the missing targets
first.
