CREATE TABLE IF NOT EXISTS analytics.steamspy_silver_int_publishers
(
    publisher_id Int64,
    publisher String,
    dt String
)
ENGINE = ReplacingMergeTree()
PARTITION BY dt
ORDER BY (publisher_id, dt)
SETTINGS index_granularity = 8192;
