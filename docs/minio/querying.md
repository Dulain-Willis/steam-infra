# Querying MinIO with DuckDB

Use `make duck` to open a DuckDB session with the local MinIO instance pre-configured. No credentials needed — they are loaded from `infra/minio/minio.sql` automatically.

## Usage

```bash
# interactive shell
make duck

# one-shot query
make duck q="<sql>"
```

Inside the interactive shell, type `.help` for a list of available commands.

## Examples

Browse silver data:
```bash
make duck q="SELECT * FROM read_parquet('s3://warehouse/steamspy/silver/data/**/*.parquet') LIMIT 10"
```

Inspect schema:
```bash
make duck q="DESCRIBE SELECT * FROM read_parquet('s3://warehouse/steamspy/silver/data/**/*.parquet')"
```

## Bucket layout

```
s3://landing/      — raw extracts
s3://warehouse/    — Iceberg tables (bronze / silver / gold)
```

Parquet files sit under `data/` within each table path, partitioned by `dt`:
```
s3://warehouse/steamspy/silver/data/dt=2026-03-28/*.parquet
```

Use `**/*.parquet` to match all partitions at once.

## Querying JSON (Iceberg metadata)

DuckDB can read JSON files directly from S3 using `read_json_auto`:

```bash
make duck q="SELECT * FROM read_json_auto('s3://warehouse/steamspy/silver/metadata/00000-1f7117ce-36a3-4c73-885c-ccc66905638e.metadata.json')"
```

Explore top-level keys first:

```bash
make duck q="SELECT json_keys(to_json(t)) FROM read_json_auto('s3://...metadata.json') t"
```

Unnest a nested array:

```bash
make duck q="SELECT unnest(snapshots) FROM read_json_auto('s3://warehouse/steamspy/silver/metadata/00000-1f7117ce-36a3-4c73-885c-ccc66905638e.metadata.json')"
```

> **Note:** Avoid `*.json` globs on Iceberg metadata — each file is a full independent snapshot, not a partition. DuckDB will union them all, which is rarely useful. Reference specific files by name instead.

---

## Querying Iceberg with spark-sql

Use `make spark` to open a `spark-sql` session inside the running `spark-master` container with the Iceberg REST catalog and MinIO credentials pre-wired via `--conf` flags. No credentials needed — they are hardcoded to the local dev defaults in the Makefile.

`iceberg` is set as the default catalog, so table names do not need the `iceberg.` prefix.

> **Requires the stack to be running** (`docker compose up -d spark-master iceberg-rest minio`).

## Usage

```bash
# interactive shell
make spark

# one-shot query
make spark q="<sql>"
```

## Examples

Describe a table's schema:
```bash
make spark q="DESCRIBE steamspy.silver"
```
```
col_name | data_type | comment
app_id   | int       |
...
```

Inspect snapshots to check replication state:
```bash
make spark q="SELECT snapshot_id, committed_at, operation FROM steamspy.silver.snapshots ORDER BY committed_at DESC"
```
```
snapshot_id          | committed_at           | operation
8347789269832479754  | 2026-04-06 21:33:04.02 | append
```

Find partitions written in snapshots after a given ID (what the replication job detects):
```bash
make spark q="SELECT DISTINCT partition.dt FROM steamspy.silver.entries WHERE snapshot_id > <last_id> AND status = 1"
```

Browse silver data:
```bash
make spark q="SELECT * FROM steamspy.silver LIMIT 10"
```

## Iceberg metadata tables

Every Iceberg table exposes metadata sub-tables you can query by appending a suffix. All of the following work against any table in the catalog (substitute `steamspy.silver` with any other table):

| Suffix | What it contains |
|---|---|
| `.snapshots` | All snapshot IDs, timestamps, and operations (`append` / `overwrite`) |
| `.history` | Snapshot lineage — parent/child relationships and current-ancestor flag |
| `.entries` | File-level manifest entries per snapshot; `status=1` means file was added. Used by the replication job for change detection |
| `.files` | Current live data files — path, format, row count, size, partition |
| `.manifests` | Manifest file list for the current snapshot with partition summaries |
| `.partitions` | Partition summary — distinct `dt` values with file and row counts |
| `.refs` | Named refs (branches / tags) pointing to snapshot IDs |

### Examples

```bash
# What partitions exist and how big are they?
make spark q="SELECT partition, file_count, record_count FROM steamspy.silver.partitions"

# What files are in a specific partition?
make spark q="SELECT file_path, record_count FROM steamspy.silver.files WHERE partition.dt = '2026-03-28'"

# Full snapshot lineage
make spark q="SELECT * FROM steamspy.silver.history"

# Drop a table (e.g. to clear stale metadata when the Iceberg catalog is out of sync with MinIO)
make spark q="DROP TABLE IF EXISTS iceberg.steamspy.silver"
```

---

## When to use Spark vs DuckDB

| | DuckDB (`make duck`) | spark-sql (`make spark`) |
|---|---|---|
| Raw Parquet files in MinIO | ✓ | — |
| Iceberg metadata tables (`.snapshots`, `.entries`, `.files`, …) | — | ✓ |
| Startup time | instant | ~30s |
