# steam-infra

Infrastructure configuration for the Steam Data Platform.

## Contents

| Path | Description |
|------|-------------|
| `terraform/` | Provisions MinIO buckets (`landing`, `warehouse`) |
| `clickhouse/init/` | ClickHouse init SQL executed on first container start |
| `minio/minio.sql` | DuckDB S3 config for querying MinIO Parquet directly |
| `docs/` | Terraform commands, Docker commands, MinIO querying guide |

## Terraform

```bash
# From steam-data-platform/ — Terraform runs in a container
docker compose run --rm terraform init
docker compose run --rm terraform apply
```

See [`docs/terraform/commands.md`](docs/terraform/commands.md) for full reference.

## ClickHouse Init

SQL files in `clickhouse/init/` run in filename order on first container start (`CLICKHOUSE_ALWAYS_RUN_INITDB_SCRIPTS=true` forces re-execution on restart when needed). Each file creates one schema object.

## Architecture Decisions

ADRs live in [`steam-data-platform/docs/decisions/`](../steam-data-platform/docs/decisions/).
