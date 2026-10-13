# steam-infra

Infrastructure for a toy, production-like CDC pipeline: RDS (Postgres) →
Debezium → Kafka → Snowflake, orchestrated by Terraform (AWS/EKS) and
ArgoCD (everything inside the cluster). Bring-up and teardown are each a
staged, verified, unattended flow so the environment costs nothing between
sessions.

## Bring up

```bash
./bringup/bringup.sh
```

Takes ~30 minutes from nothing to a verified, data-flowing pipeline,
unattended. Runs teardown first if it detects leftovers from a previous
session. Flags:

- `--start-from N` — resume after a partial run (skips stage 1's
  leftover-teardown check, so resuming never destroys what's already up).
- `--stop-after N` — stop after stage N, to test a partial bring-up.

Each stage script in `bringup/stages/` is also runnable on its own, e.g.
`bringup/stages/03-aws.sh`, to debug one stage in isolation. Noisy tool
output (tofu, kubectl, helm) is logged under `/tmp`; a failing step prints
the tail of its log.

## Tear down

```bash
./teardown/teardown.sh
```

Takes everything back to $0 billable in AWS and Snowflake, and proves it.
Same `--start-from`/`--stop-after` flags; same per-stage scripts in
`teardown/stages/`.

## One-time setup

1. A Snowflake account, with a user holding `ACCOUNTADMIN`. That is the
   bootstrap identity only: it is what OpenTofu creates the databases, roles
   and service users as. Nothing in the pipeline itself runs as it — the
   Kafka sink and Airflow each authenticate as their own service user with a
   least-privilege role (see Conventions below).
2. Generate an RSA key pair and register the public half on that user:
   ```bash
   openssl genpkey -algorithm RSA -out .secrets/snowflake_key.p8 -pkeyopt rsa_keygen_bits:2048
   openssl rsa -in .secrets/snowflake_key.p8 -pubout -out .secrets/snowflake_key.pub
   ```
   Then, in a Snowflake worksheet:
   ```sql
   ALTER USER <user> SET RSA_PUBLIC_KEY='<contents of .pub, header/footer/newlines stripped>';
   ```
3. Copy `.env.example` to `.env` and fill in `SNOWFLAKE_ACCOUNT`,
   `SNOWFLAKE_ORGANIZATION_NAME`, `SNOWFLAKE_ACCOUNT_NAME`,
   `SNOWFLAKE_USER`, `SNOWFLAKE_PRIVATE_KEY_PATH` (defaults to the key
   above), and `AIRFLOW_ALERT_EMAIL`.

   The account identifier is needed in both forms: the OpenTofu provider
   wants it split (`organization_name` + `account_name`), while the Python
   connector, the Kafka sink and dbt want the combined `<ORG>-<ACCOUNT>`.
   Get the two halves from a worksheet:
   ```sql
   SELECT CURRENT_ORGANIZATION_NAME(), CURRENT_ACCOUNT_NAME();
   ```
   `CURRENT_ACCOUNT()` is *not* it — that returns the account locator, which
   does not resolve as part of an account identifier. Preflight fails if
   `SNOWFLAKE_ACCOUNT` isn't `<ORG>-<ACCOUNT>`, so the two can't drift.
4. Install [`uv`](https://docs.astral.sh/uv/) — the only Python
   prerequisite; every Python script here runs through it, so the host's
   system Python is never touched. `tofu`, `aws`, `kubectl`, `helm`, `jq`,
   `psql`, `gh` and the SSM `session-manager-plugin` are also required;
   preflight checks for all of them before anything else runs. `gh` is
   Stage 2's: it pushes the CI identity's rotating credentials to
   steam-analytics' Actions secrets, so it needs a token with `repo` scope on
   that repository (`gh auth status`).

## Conventions fixed for every copy of this repo

Not configurable via `.env` — same for every environment:

- Snowflake databases `STEAM_RAW` (CDC landing tables, in schema
  `STEAM_RDS` — named after the source system), `STEAM_STAGING` and
  `STEAM_PROD` (staging's and prod's dbt builds, in bare layer schemas) and
  `STEAM_DEV` (every developer's and every PR's build, in prefixed schemas
  `dbt_<name>_<layer>` / `ci_pr_<N>_<layer>`), warehouse `COMPUTE_WH`.
- Snowflake roles, each reading and writing exactly what its job needs:

  | Role | Reads | Writes |
  |---|---|---|
  | `LOADER` | — | `STEAM_RAW` |
  | `TRANSFORMER_STAGING` | `STEAM_RAW` | `STEAM_STAGING` |
  | `TRANSFORMER_PROD` | `STEAM_RAW` | `STEAM_PROD` |
  | `DEVELOPER` | `STEAM_RAW` | `STEAM_DEV` |
  | `CI` | `STEAM_RAW`, `STEAM_PROD` | `STEAM_DEV` |

  All but `DEVELOPER` are granted to exactly one service user each, whose RSA
  key pair OpenTofu generates; bring-up copies the two Airflow ones into a
  Kubernetes Secret and the CI one into steam-analytics' Actions secrets.
  `DEVELOPER` is granted to one `STEAM_DEV_<NAME>` user per entry in
  `terraform/snowflake`'s `developers` variable — onboarding a teammate is
  that one entry, holding their name and their RSA *public* key. Bring-up
  asserts every boundary both ways before it continues.

  `CI` reading `STEAM_PROD` is the one asymmetry: slim CI defers unchanged
  models to prod's state, so it has to `SELECT` prod's relations. `DEVELOPER`
  deliberately has no grant there at all, which is what makes "a dev build
  changes nothing in `STEAM_PROD`" provable rather than asserted.
- AWS region `us-east-1`.

## Edit these when you copy the repo

Account-specific values that can't come from `.env` or `tofu output`:

- The developers — the `developers` variable's default in
  `terraform/snowflake/variables.tf`. It ships with this project's operator and
  their RSA public key; replace the entry rather than adding to it, or the next
  bring-up creates a Snowflake user for a stranger.
- The ArgoCD repo URL — `repoURL` in `argocd/root.yaml` and every
  `argocd/apps/*.yaml`.
- The analytics repository whose Actions secrets Stage 2 writes —
  `ANALYTICS_REPO` in `scripts/lib/env.sh`.
- The ECR image URL — `image` in `k8s/kafka/connect/kafka-connect.yaml`.
- The tfstate bucket — `bucket` in `terraform/backend.tf` and
  `terraform/snowflake/backend.tf` (and the matching `aws_s3_bucket.tfstate`
  name in `terraform/tfstate_backend.tf`).
- The RDS hostname — `database.hostname` in
  `k8s/kafka/connectors/debezium-connector.yaml` (get it with
  `cd terraform && tofu output -raw rds_endpoint`).

## Layout

- `bringup/`, `teardown/` — entrypoint scripts and their numbered stages.
- `lib/` — shared library: terminal output helpers, `.env`/tofu wrappers,
  the SSM tunnel, and the Snowflake query helper used by both flows' verify
  steps.
- `terraform/` — AWS infrastructure (network, EKS, RDS, ECR, bastion,
  tfstate backend). Everything below the AWS/EKS layer is ArgoCD's.
- `terraform/snowflake/` — a second root module, own state key in the same
  bucket, owning the Snowflake side (the database today; roles, users and
  grants later). Separate state so a Snowflake change can't block an AWS
  plan or the other way round.
- `argocd/`, `k8s/` — the ArgoCD app-of-apps tree and the manifests it
  points at (Strimzi, Kafka, Kafka Connect, the connectors, Airflow).
- `generator/` — the EC2-hosted event generator that ticks against RDS.
- `scripts/` — the end-to-end smoke test, reused as bring-up's final
  verify step.
- `db/schema.sql` — the full OLTP schema (no separate migrations — this
  file is always current).
- `docs/` — ADRs and standalone runbooks/decision records.
