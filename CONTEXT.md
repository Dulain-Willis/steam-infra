# steam-infra

## Single-tenant AWS account

This project owns its AWS account outright. Nothing else runs in it, in any
region. Two things depend on that and would be unsafe without it:

- **Teardown's `$0` verify** (`scripts/teardown/stages/06-verify.sh`) checks
  account-wide in the project region rather than matching tags, so it also
  catches resources Kubernetes created that Terraform never knew about —
  dynamically provisioned EBS volumes in particular.
- **Teardown's orphan sweeps** (`scripts/lib/teardown_sweep.sh`) identify
  CSI-provisioned EBS volumes by the PVC namespace the driver tags them with,
  not by cluster: there is no cluster-identifying tag on them to use. A second
  EKS cluster in this region with an `airflow` or `kafka` namespace would be
  in scope of that sweep.

Both files cite this section. If the account ever stops being single-tenant,
they are the two places to revisit — and `cluster_volumes`' `ponytail:` note
records the proper fix (set `--k8s-tag-cluster-id` on the CSI addon).

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

**Environment** — one of three isolated copies of the Airflow pipeline,
each with its own Airflow metadata, secrets, Snowflake identity and
Snowflake database. dbt gets an environment only because Airflow runs it.

- **dev** — Airflow running locally in Docker on a developer's machine,
  building into that developer's own schemas in `STEAM_DEV`. *Avoid*
  "local" as a separate environment name — local *is* dev.
- **staging** — the prod-like Airflow on EKS that runs only merged code,
  building into `STEAM_STAGING`. Not to be confused with the dbt **stg
  layer**.
- **prod** — the production Airflow on EKS, building into `STEAM_PROD`.

**Promotion** — moving an already-built image tag from staging to prod.
The image is never rebuilt between environments. Mechanically: the
**Promote to prod** workflow opens a PR setting prod's image tag to
staging's, and merging that PR is both the approval and the deploy
(README.md, "Promote to prod"). Rollback is the same thing with an older
tag.

**Schema evolution** — a change to a source table's shape made directly
against the live database (an `alter table`), outside any coordinated
release. *Additive* schema evolution (a new nullable column — the only
kind `scenarios/games_add_column.py` models, #144) needs no coordinated
release at all: Snowflake's own schema-evolution feature
(`snowflake.enable.schematization=true`, steam-analytics ADR 0001) picks
up the new column in the landing table automatically on the connector's
next change event, and every `stg` model keeps building unchanged
because it already names its output columns explicitly rather than
`select *`-ing the landing table. A *breaking* schema evolution (a
rename, a type change, a drop) is a deliberate follow-up, out of scope
here — see **contract** below for how steam-analytics catches that case
instead of silently reshaping a table someone depends on.

**Contract** — a declared, enforced shape (column names and types) on a
dbt model's output, set via `config: {contract: {enforced: true}}` plus a
`data_type` on every output column in that model's schema yml
(steam-analytics). Declared only on *published* mart models (see that
repo's `CONTEXT.md`) — the layer other teams and BI tools build on. A
model change that would alter a contracted column's name or type fails
the build instead of landing silently; an *additive* source-side change
(see **schema evolution** above) never trips it, because a contract only
constrains columns a model actually declares, not every column that
happens to exist upstream.

See `docs/adr/0001-argocd-reverses-iac-boundary-28.md` for why ArgoCD owns
this layer instead of Terraform or hand-run `kubectl`.
