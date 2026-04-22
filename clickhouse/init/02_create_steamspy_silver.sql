CREATE TABLE IF NOT EXISTS analytics.steamspy_silver_stg_games
(
    appid Int32,
    game_title Nullable(String),
    developer Nullable(String),
    publisher Nullable(String),
    score_rank Nullable(String),
    positive Int32,
    negative Int32,
    userscore Int32,
    owners Nullable(String),
    average_forever Int32,
    average_2weeks Int32,
    median_forever Int32,
    median_2weeks Int32,
    ccu Int32,
    price Nullable(String),
    initialprice Nullable(String),
    discount Nullable(String),
    run_id String,
    ingestion_timestamp DateTime64(3),
    dt String
)
ENGINE = ReplacingMergeTree(ingestion_timestamp)
PARTITION BY dt
ORDER BY (appid, dt)
SETTINGS index_granularity = 8192;
