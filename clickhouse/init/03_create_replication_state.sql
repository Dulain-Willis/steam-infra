CREATE TABLE IF NOT EXISTS analytics.replication_state
(
    table_name         String,
    last_snapshot_id   Nullable(Int64),
    last_replicated_at Nullable(DateTime64(3)),
    updated_at         DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY table_name;
