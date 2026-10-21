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

See `docs/adr/0001-argocd-reverses-iac-boundary-28.md` for why ArgoCD owns
this layer instead of Terraform or hand-run `kubectl`.

**Request-then-execute sequence** — the documented shape of compliance
erasure: a deletion *request* is recorded first (`users.deletion_requested_at`
set, nothing deleted), then — only after a restoration grace period has
elapsed with no reversal — the *execute* phase runs an actual hard delete
(#143). This makes the sequence the pipeline has to handle a soft delete
(the request, an ordinary `UPDATE`) followed later by a hard delete,
which is the one documented exception to this repo's otherwise-universal
soft-delete convention (`db/schema.sql:4`, "Revocation/end pattern:
nullable `*_at` column, never delete rows") rather than a contradiction
of it. See `scenarios/deletion_request.py` (marks the request) and
`scenarios/deletion_reversal.py` (reverses it within the grace period).

**Retention tier** — one of the three buckets `scenarios/deletion_execution.py`
(#143) sorts a user's data into once their deletion request's grace period
elapses: **hard delete** (behavioural data with no retention duty —
`client_events`, `playtime_sessions`, `wishlist_items` — rows removed
outright), **anonymize in place** (the `users` row itself — kept, with
`username`/`email` overwritten by a tombstone value and `country` cleared,
so every foreign key into it stays intact), and **retain untouched**
(`purchases`, `refunds`, `ownership_grants` — left exactly as they are
under statutory commercial/tax retention, which overrides the erasure
request). Not a cascade: which tier a table falls into is a fixed,
per-table decision, not something inherited by following a foreign key
down from `users`. See
`docs/adr/0004-three-tier-compliance-erasure-143.md`.
