# ADR 0001: ArgoCD reverses the Terraform/kubectl IaC boundary from #28

## Status

Accepted.

## Context

#28 drew the original IaC boundary for the k8s-level pipeline: Terraform
would own the EKS cluster and the Strimzi operator install (as a
`helm_release`), while the Kafka cluster CRD, Kafka Connect, and the
Debezium/Snowflake connectors would be applied by hand with `kubectl`,
following a written runbook (the now-retired `docs/kafka-connect-runbook.md`).
That boundary is recorded in comments on `terraform/strimzi.tf` and
`terraform/ecr.tf`.

In practice this split two things that needed to be reasoned about
together — the Strimzi operator and Airflow lived in Terraform state as
`helm_release` resources, while the Kafka cluster, Connect, and the
connectors were manual `kubectl apply` steps with no source of truth
tracking whether the live cluster actually matched the repo. There was no
drift detection, and rebuilding the stack meant re-walking a runbook
rather than reading a declarative tree.

## Decision

Introduce ArgoCD as the GitOps controller for everything below the EKS
cluster level. Terraform's scope narrows to pure AWS/EKS bring-up (network,
EKS, RDS, ECR, bastion, tfstate backend) plus nothing at the Kubernetes-
application layer. Every k8s-level component — the Strimzi operator, the
Kafka cluster, Kafka Connect, the Debezium/Snowflake connectors, and
Airflow — is now an ArgoCD Application, organized as an app-of-apps tree
rooted at `argocd/root.yaml`. ArgoCD manages its own Helm release the same
way, so its own upgrades are a git commit rather than a remembered manual
`helm upgrade`.

This reverses #28's boundary: Terraform no longer owns any `helm_release`.
`terraform/strimzi.tf` and `terraform/airflow.tf` (the latter from #25) were
removed after `terraform state rm`-ing their `helm_release` resources —
adopted in place by ArgoCD with no downtime to the running components.
`terraform/ecr.tf`'s reasoning ("Terraform owns this because it's a plain
AWS resource, not a k8s CRD") still holds; ECR is exactly the kind of
AWS-only resource that stays in Terraform under the new boundary.

## Consequences

- A single place (`kubectl get application -n argocd`, or the ArgoCD UI via
  `kubectl port-forward svc/argocd-server -n argocd`) now shows whether the
  cluster matches the repo, for every k8s-level component at once.
- `docs/kafka-connect-runbook.md` is retired — its bring-up steps are
  superseded by ArgoCD Application sync; its teardown step (dropping the
  Debezium replication slot before `tofu destroy`) moved to
  `docs/rds-bootstrap.md`, since that's independent of how the Kafka
  resources get applied.
- The Kafka cluster and Kafka Connect Applications require manual sync
  approval (the stateful Kafka layer); Airflow, the connectors, and
  ArgoCD's own Application auto-sync with `selfHeal` and `prune`.
- Adopting `kafka-connect.yaml` into ArgoCD surfaced a latent bug: the
  committed manifest had a literal `<account-id>` placeholder meant for
  hand-substitution before `kubectl apply`. GitOps applies exactly what's
  committed, so this had to be fixed with the real ECR repo URL — a
  concrete instance of the kind of drift this ADR's decision is meant to
  prevent going forward.
