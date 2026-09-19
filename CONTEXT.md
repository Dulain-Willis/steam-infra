# steam-infra

## Glossary

**Application** — an ArgoCD custom resource (`argoproj.io/v1alpha1
Application`) that syncs one source (a Helm chart or a git path) to one
destination namespace, and reports `Synced`/`Healthy` status for it. This is
ArgoCD's meaning throughout `argocd/` and this repo's docs — not "a
deployable program." Each k8s-level component (the Strimzi operator, the
Kafka cluster, Kafka Connect, the connectors, Airflow, and ArgoCD itself)
is exactly one Application.

**app-of-apps** — the pattern where one Application's source is a
directory of other Application manifests, so applying that one root
Application bootstraps the whole tree. `argocd/root.yaml` is this repo's
root Application; its source is `argocd/apps/`, which holds one Application
manifest per managed component. Adding a new k8s-level component means
adding one file under `argocd/apps/` — no new imperative bootstrap step.

See `docs/adr/0001-argocd-reverses-iac-boundary-28.md` for why ArgoCD owns
this layer instead of Terraform or hand-run `kubectl`.
