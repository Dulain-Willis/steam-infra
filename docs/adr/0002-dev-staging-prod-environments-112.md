# ADR 0002: dev/staging/prod environments for Airflow, and the Snowflake layout they need from #112

## Status

Accepted.

## Context

Before this spec there was exactly one environment: Airflow on EKS ran the
dbt project against a single Snowflake database (`STEAM_PROJECT`) as
`ACCOUNTADMIN`, and the CDC connector landed into that same database's
`PUBLIC` schema. A local dbt run, a local Airflow run, a PR's CI build and
production all wrote into the same layer schemas (`stg`, `int`, `marts_*`).
Nothing was prod-like before prod, and no identity boundary stopped dev work
from touching production data.

#112 asked for three environments — **dev**, **staging** and **prod** — with
least-privilege Snowflake identities enforcing the boundary between them,
and a Snowflake layout the whole pipeline reads and writes honestly.

## Decision

**Airflow defines the environments; dbt gets one because Airflow runs it.**
dev is Airflow running locally in Docker compose on a developer's machine
(`steam-orchestration`'s `make up`); staging and prod are two Airflow
releases on the same EKS cluster. dbt's `dev`/`ci`/`staging`/`prod` targets
exist because each is driven by one of those Airflow deployments (or, for
`dev`, no Airflow at all) — dbt does not invent a fourth environment of its
own.

**Staging and prod are namespaces on one cluster, not separate clusters or
AWS accounts.** Both are the Apache Airflow Helm chart deployed into their
own Kubernetes namespace (`airflow`, `airflow-staging`), each with its own
chart-managed metadata Postgres, its own Kubernetes Secrets, and its own
Snowflake service identity. Isolation is namespace + metadata-database +
secrets + Snowflake grants, not infrastructure replication. This was
explicitly in scope's "Out of Scope" list from the start: a second cluster
or account per environment buys nothing here and would double the AWS
surface for a toy project modelling a production team, not running one.

**Every environment reads one shared raw database, `STEAM_RAW`, and writes
its own.** The CDC connector lands into `STEAM_RAW.STEAM_RDS` (named after
the source system, Postgres-on-RDS, not after the database engine) using the
`LOADER` role, and that is the only writer. Every other role reads it.
Each environment's build goes into its own database:

| Environment | Database | Schema naming |
|---|---|---|
| dev (a developer's own build, with or without local Airflow) | `STEAM_DEV` | `dbt_<name>_<layer>` |
| dev (a PR's CI build) | `STEAM_DEV` | `ci_pr_<N>_<layer>` |
| staging | `STEAM_STAGING` | bare (`stg`, `int`, `marts_*`) |
| prod | `STEAM_PROD` | bare (`stg`, `int`, `marts_*`) |

**Each environment's identity is least-privilege by grant, not by
convention.** `terraform/snowflake/identities.tf` declares one role and one
service user per writer (`LOADER`, `TRANSFORMER_STAGING`, `TRANSFORMER_PROD`,
`CI`), plus `DEVELOPER` granted to one user per entry in a declared
`developers` list:

| Role | Reads | Writes |
|---|---|---|
| `LOADER` | — | `STEAM_RAW` |
| `TRANSFORMER_STAGING` | `STEAM_RAW` | `STEAM_STAGING` |
| `TRANSFORMER_PROD` | `STEAM_RAW` | `STEAM_PROD` |
| `DEVELOPER` | `STEAM_RAW` | `STEAM_DEV` |
| `CI` | `STEAM_RAW`, `STEAM_PROD` (tables **and** views) | `STEAM_DEV` |

Nothing in the pipeline runs as `ACCOUNTADMIN` any more; that identity is
left as OpenTofu's own bootstrap role, the one thing that has to be able to
create roles and users in the first place. Bring-up proves the boundary
rather than trusting the grants: each service user authenticates with its
own tofu-generated key pair and is made to attempt both a permitted write
and a forbidden one (`scripts/lib/grant_check.sh`), and a separate read-deny
check covers the databases no `GRANT_CASES` write probe reaches (a role
having no grant of any kind — not even `USAGE` — on a database it must never
touch).

**The CI identity's grants, chosen explicitly for #112 story 17-20 (the AC
this ADR records):**

| Object | Privileges |
|---|---|
| warehouse `COMPUTE_WH` | `USAGE` |
| database `STEAM_DEV` | `USAGE`, `CREATE SCHEMA` |
| all schemas in `STEAM_DEV` | `USAGE`, `CREATE TABLE`, `CREATE VIEW` |
| future schemas in `STEAM_DEV` | `USAGE`, `CREATE TABLE`, `CREATE VIEW` |
| database `STEAM_RAW` | `USAGE` |
| all schemas in `STEAM_RAW` | `USAGE` |
| future schemas in `STEAM_RAW` | `USAGE` |
| all tables in `STEAM_RAW` | `SELECT` |
| future tables in `STEAM_RAW` | `SELECT` |
| database `STEAM_PROD` | `USAGE` |
| all schemas in `STEAM_PROD` | `USAGE` |
| future schemas in `STEAM_PROD` | `USAGE` |
| all **tables and views** in `STEAM_PROD` | `SELECT` |
| future **tables and views** in `STEAM_PROD` | `SELECT` |
| `STEAM_STAGING` | nothing, of any kind |

A dedicated role and service user (`CI` / `STEAM_CI_SVC`), not a reuse of
`DEVELOPER`: CI needs read on `STEAM_PROD` for slim-CI deferral and
`DEVELOPER` must not have it, granting it would hand prod read to every
developer and make "a dev build changes nothing in `STEAM_PROD`" unprovable;
CI's key is also the one identity whose private key leaves the cluster
(pushed into GitHub Actions secrets), so it is the one that most needs to be
revocable independently; and query history attributes CI's work to
`STEAM_CI_SVC` instead of to a human.

**Prod's read grant needs views as well as tables, and this was not
obvious.** The stg and int layers are materialized as dbt views; `SELECT` on
a view is a separate Snowflake grant from `SELECT` on a table. A tables-only
grant would have let slim CI defer correctly to a mart (a table) and then
fail reading anything upstream of one (a view) with "Object does not exist",
which reads as a dbt bug rather than a missing grant. Both halves are
granted via `for_each = toset(["TABLES", "VIEWS"])`, and bring-up probes
both explicitly (`grant_handoff_check ... TABLE VIEW`) rather than trusting
one case to stand in for the other.

**Promotion is a manual PR, not Kargo and not a time-based soak.** A merge
to `main` in `steam-orchestration` or `steam-analytics` builds one image and
writes its tag into staging's image values only
(`k8s/airflow/values-image-staging.yaml`); ArgoCD rolls staging onto it
automatically. Moving that same image to prod is a separate,
manually-triggered GitHub Action (`promote-to-prod.yml`) that opens a PR
changing exactly one line — `defaultAirflowTag` in
`k8s/airflow/values-image-prod.yaml` — to staging's current tag, or to an
explicitly named older tag for a rollback. **Merging that PR is the
approval and the deploy**, because every ArgoCD Application tracks
`targetRevision: main`; there is no step after the merge. Kargo (staging
verification via an `AnalysisTemplate` job, automatic promotion to prod) and
a time-based soak period were both evaluated during design and declined:
this project has no on-call rotation and no traffic to analyze a soak
against, so either mechanism would be machinery simulating a judgment call
a human is right there to make by reviewing one diff line. A tag is only
promotable if it has actually appeared in one of the two image files
(currently, or in their git history) — enforcing "every tag reaching prod
ran in staging first" structurally, rather than by convention, with no GHCR
call needed.

**Helm: one base, one overlay per environment — and the overlay has to
carry the whole `extraEnv` block, not just what differs.** The Airflow
chart's `extraEnv` value is a single raw YAML-shaped string. Helm replaces
string and list values wholesale rather than merging them, so a base
`extraEnv` plus an overlay `extraEnv` would make the base's content vanish
silently — no error, just missing environment variables at pod start. The
split therefore keeps every *map*-typed value (`config.*`,
`migrateDatabaseJob`, shared `ingress` annotations) in the base, where Helm
does merge key-by-key, and puts the entire `extraEnv` block — six values'
worth of actual difference (`SNOWFLAKE_ROLE`, `SNOWFLAKE_DATABASE`,
`DBT_TARGET`, `AIRFLOW__API__BASE_URL`, the ingress `path`, the ALB
`group.order`) — in each environment's overlay file, byte-identical apart
from those six lines. That is the honest version of story 28's "share the
base and differ only in a small overlay": every mergeable key is shared,
and the one key that cannot merge is duplicated whole rather than split.
`scripts/check-airflow-values.sh` is the mechanical guard that nothing
environment-specific leaks back into the base.

## Consequences

- **ArgoCD reads GitHub's `main`, never a branch or local disk**, because
  every Application's `targetRevision` is `main`. This means no infra
  change — a new Snowflake grant, a new Airflow overlay, a new ArgoCD
  Application — is prod-like, or testable against a live cluster at all,
  before it merges. This is the spec's own opening complaint ("nothing is
  prod-like before prod") recurring one level further down the stack: the
  environments this spec built cannot themselves be verified pre-merge.
  The cold acceptance run for this spec worked around it with two temporary
  `GATE ONLY` commits repointing `targetRevision` at the integration branch
  for the duration of the gate, reverted before the spec's PRs merged. That
  workaround is not a fix; a durable answer (an ephemeral preview
  Application per branch, or a `targetRevision` templated from a PR
  comment) is future work this spec did not attempt.
- **`fct_source_freshness` has no producer.** `dbt source freshness` calls
  `RunTask.after_run`, which fires dbt's `on-run-end` hook — and that hook,
  gated on `target.name in ('prod', 'staging')`, is what makes elementary
  write `fct_source_freshness` rows. Running the freshness check on the
  `prod` target from GitHub Actions would therefore make the CI identity
  — deliberately read-only on `STEAM_PROD` — attempt to write
  `STEAM_PROD.elementary` and fail; granting CI write there, or putting
  prod's writer key in GitHub secrets, both reopen exactly the isolation
  this design exists to close. `source-freshness.yml` runs on the `ci`
  target instead, which is not gated, so the freshness checks themselves
  are unaffected but elementary never captures their results from that
  workflow. The correct home for a `dbt source freshness` task that
  actually populates `fct_source_freshness` is prod Airflow's own DAG,
  where `TRANSFORMER_PROD`'s key never leaves the cluster. This spec left
  the workflow as a read-only spot-check and did not add the DAG task;
  #116 and #121 both record this as open.
- **The chart-generated `fernetKey`, `apiSecretKey` and `jwtSecret` rotate
  on every ArgoCD sync**, and this spec deliberately left that alone in
  both the base/prod split (#118) and the staging addition (#119). The
  fernet key encrypts Airflow *Connections* in the metadata database; there
  are none — every credential arrives as an environment variable from a
  Kubernetes Secret, the one `conn_id` the DAG names (`smtp_default`) is
  never created by bring-up, and the metadata database itself lives on a
  PVC that every teardown destroys. Rotation costs only logged-in UI
  sessions in a cluster that is brought up and torn down whole. If a future
  change ever stores an Airflow Connection or Variable, this becomes a
  data-loss risk rather than a session annoyance and should be fixed
  immediately by pinning the three `*SecretName` values to bring-up-created
  Secrets — the base values file is already shaped to take them.
- **Onboarding a developer, or revoking CI's or an environment's key, is a
  one-line change plus a bring-up**, not a manual Snowflake session: the
  `developers` list, the per-role service users, and their RSA key pairs
  are all declared in `terraform/snowflake`, and bring-up both generates
  the keys and pushes the ones that leave the cluster (CI's, into GitHub
  Actions secrets).
- **The Snowflake grant boundary is proven on every bring-up, not just
  designed once.** `scripts/lib/grant_check.sh`, run against a stubbed
  Snowflake by `scripts/lib/grant_check_test.sh`, is exercised live by Stage
  2 of `bringup.sh` against every role this ADR lists; a future role added
  without a corresponding deny case is a gap the test suite is built to
  surface, per the invariant that every deny target must also be some
  identity's allow target.
