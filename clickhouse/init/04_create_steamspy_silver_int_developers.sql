CREATE TABLE IF NOT EXISTS analytics.steamspy_silver_int_developers
(
    developer_id Int64,
    developer String,
    dt String
)
ENGINE = ReplacingMergeTree()
PARTITION BY dt
ORDER BY (developer_id, dt)
SETTINGS index_granularity = 8192;
