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
`bringup/stages/02-aws.sh`, to debug one stage in isolation. Noisy tool
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

1. A Snowflake account, with a user that can `CREATE`/`DROP DATABASE` and
   create tables (role `ACCOUNTADMIN` by default — see Conventions below).
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
   `SNOWFLAKE_USER`, `SNOWFLAKE_PRIVATE_KEY_PATH` (defaults to the key
   above), and `AIRFLOW_ALERT_EMAIL`.
4. Install [`uv`](https://docs.astral.sh/uv/) — the only Python
   prerequisite; every Python script here runs through it, so the host's
   system Python is never touched. `tofu`, `aws`, `kubectl`, `helm`, `jq`,
   `psql`, and the SSM `session-manager-plugin` are also required; preflight
   checks for all of them before anything else runs.

## Conventions fixed for every copy of this repo

Not configurable via `.env` — same for every environment:

- Snowflake database `STEAM_PROJECT`, role `ACCOUNTADMIN`, warehouse
  `COMPUTE_WH`, schema `PUBLIC`.
- AWS region `us-east-1`.

## Edit these when you copy the repo

Account-specific values that can't come from `.env` or `tofu output`:

- The ArgoCD repo URL — `repoURL` in `argocd/root.yaml` and every
  `argocd/apps/*.yaml`.
- The ECR image URL — `image` in `k8s/kafka/connect/kafka-connect.yaml`.
- The tfstate bucket — `bucket` in `terraform/backend.tf` (and the matching
  `aws_s3_bucket.tfstate` name in `terraform/tfstate_backend.tf`).
- The RDS hostname — `database.hostname` in
  `k8s/kafka/connectors/debezium-connector.yaml` (get it with
  `cd terraform && tofu output -raw rds_endpoint`).

## Layout

- `bringup/`, `teardown/` — entrypoint scripts and their numbered stages.
- `lib/` — shared library: terminal output helpers, `.env`/tofu wrapper,
  the SSM tunnel, and the Snowflake database helper, used by both flows.
- `terraform/` — AWS infrastructure (network, EKS, RDS, ECR, bastion,
  tfstate backend). Everything below the AWS/EKS layer is ArgoCD's.
- `argocd/`, `k8s/` — the ArgoCD app-of-apps tree and the manifests it
  points at (Strimzi, Kafka, Kafka Connect, the connectors, Airflow).
- `generator/` — the EC2-hosted event generator that ticks against RDS.
- `scripts/` — the end-to-end smoke test, reused as bring-up's final
  verify step.
- `db/schema.sql` — the full OLTP schema (no separate migrations — this
  file is always current).
- `docs/` — ADRs and standalone runbooks/decision records.
