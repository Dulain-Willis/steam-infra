-- Fake Steam OLTP schema
-- PKs: uuid (gen_random_uuid()) | money: integer cents | timestamps: timestamptz UTC
-- Event tables carry both an event-time column and recorded_at (when OLTP wrote the row)
-- Revocation/end pattern: nullable *_at column, never delete rows

create extension if not exists pgcrypto;

-- Debezium's pgoutput plugin needs the connecting user in the rds_replication
-- role (RDS's substitute for the superuser-only REPLICATION privilege). Applied
-- here rather than in Terraform to avoid pulling in a Postgres provider for one
-- GRANT — schema.sql already runs as the master user. See
-- docs/debezium-postgres-config.md.
grant rds_replication to steam_proj_admin;

-- ==================== ENTITY / STATE TABLES ====================

create table users (
    id uuid primary key default gen_random_uuid(),
    username text not null unique,
    email text not null unique,
    created_at timestamptz not null default now()
);

create table games (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    developer text,
    publisher text,
    genres text[] not null default '{}',
    languages text[] not null default '{}',
    tags jsonb not null default '{}',
    created_at timestamptz not null default now()
);

create table game_prices (
    id uuid primary key default gen_random_uuid(),
    game_id uuid not null references games(id),
    region text not null,               -- e.g. 'US', 'EU', 'BR'
    currency text not null,             -- ISO 4217, e.g. 'USD'
    price_cents bigint not null,
    updated_at timestamptz not null default now(),
    unique (game_id, region)
);
create index on game_prices (game_id);

create table marketing_campaigns (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    channel text not null check (channel in ('paid_search', 'paid_social', 'email', 'influencer', 'affiliate')),
    spend_cents bigint not null check (spend_cents >= 0),    -- total campaign spend, no daily breakdown
    currency text not null default 'USD' check (currency = 'USD'),   -- USD-flat; drop the check if multi-currency spend ever lands
    starts_at timestamptz not null,
    ends_at timestamptz not null,
    created_at timestamptz not null default now(),
    check (ends_at > starts_at)
);

-- ==================== EVENT TABLES ====================

create table purchases (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references users(id),      -- buyer, not necessarily owner (gifts)
    game_id uuid not null references games(id),
    amount_cents bigint not null,
    currency text not null,
    payment_method text not null,
    purchased_at timestamptz not null,
    recorded_at timestamptz not null default now()
);
create index on purchases (user_id);
create index on purchases (game_id);

create table ownership_grants (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references users(id),       -- owner
    game_id uuid not null references games(id),
    source text not null check (source in ('purchase', 'gift', 'key_redemption')),
    source_id uuid not null,                          -- points into purchases/gifts/key_redemptions (no FK: polymorphic)
    granted_at timestamptz not null,
    revoked_at timestamptz,                            -- set by a refund
    recorded_at timestamptz not null default now()
);
create index on ownership_grants (user_id, game_id);

create table gifts (
    id uuid primary key default gen_random_uuid(),
    purchase_id uuid not null references purchases(id),
    sender_id uuid not null references users(id),
    recipient_id uuid not null references users(id),
    sent_at timestamptz not null,
    redeemed_at timestamptz,                            -- null until recipient redeems (natural late-arriver)
    recorded_at timestamptz not null default now()
);
create index on gifts (recipient_id);

create table key_redemptions (
    id uuid primary key default gen_random_uuid(),
    key_hash text not null unique,
    user_id uuid not null references users(id),
    game_id uuid not null references games(id),
    redeemed_at timestamptz not null,
    recorded_at timestamptz not null default now()
);
create index on key_redemptions (user_id);

create table refunds (
    id uuid primary key default gen_random_uuid(),
    purchase_id uuid not null references purchases(id),
    reason text,
    is_chargeback boolean not null default false,
    refunded_at timestamptz not null,
    recorded_at timestamptz not null default now()
);
create index on refunds (purchase_id);

create table family_shares (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null references users(id),
    borrower_id uuid not null references users(id),
    started_at timestamptz not null,
    ended_at timestamptz,
    recorded_at timestamptz not null default now()
);
create index on family_shares (owner_id);
create index on family_shares (borrower_id);

create table wishlist_items (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references users(id),
    game_id uuid not null references games(id),
    added_at timestamptz not null,
    removed_at timestamptz,
    recorded_at timestamptz not null default now()
);
create index on wishlist_items (user_id);

create table playtime_sessions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references users(id),
    game_id uuid not null references games(id),
    started_at timestamptz not null,
    ended_at timestamptz,                               -- null until session reported closed (natural late-arriver)
    recorded_at timestamptz not null default now()
);
create index on playtime_sessions (user_id, game_id);

create table reviews (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references users(id),
    game_id uuid not null references games(id),
    recommended boolean not null,
    playtime_at_review_minutes integer not null default 0,
    submitted_at timestamptz not null,
    recorded_at timestamptz not null default now(),
    unique (user_id, game_id)
);

create table price_changes (
    id uuid primary key default gen_random_uuid(),
    game_id uuid not null references games(id),
    region text not null,
    currency text not null,
    old_price_cents bigint,
    new_price_cents bigint not null,
    changed_at timestamptz not null,
    recorded_at timestamptz not null default now()
);
create index on price_changes (game_id);

create table concurrent_player_snapshots (
    id uuid primary key default gen_random_uuid(),
    game_id uuid not null references games(id),
    player_count integer not null,
    snapshot_at timestamptz not null,
    recorded_at timestamptz not null default now()
);
create index on concurrent_player_snapshots (game_id, snapshot_at);
