# Generator runbook

First-time / from-scratch bring-up (RDS + schema + seed + generator, in the
order that avoids the crash-loop below) is `./scripts/bootstrap.sh` — see
`docs/rds-bootstrap.md`. Everything past this point assumes that's already
been run at least once.

The generator EC2 instance runs a Docker container that ticks against
Postgres over the private VPC on a jittered interval, picking an event
type by weight and writing the corresponding rows. Registered event types:

- `purchase` — writes a `purchases` row and the fan-in `ownership_grants` row.
- `gift` — two-phase: sends a new `gifts` row (`redeemed_at` null), or
  redeems an existing unredeemed one, writing the fan-in
  `ownership_grants` row only at redemption time.
- `key_redemption` — writes a `key_redemptions` row and the fan-in
  `ownership_grants` row.
- `refund` — writes a `refunds` row against an existing purchase and sets
  `revoked_at` on the matching `ownership_grants` row (never deletes or
  duplicates it).
- `price_change` — nudges a random `game_prices` row and writes the
  `price_changes` audit row.
- `concurrent_player_snapshot` — writes a `concurrent_player_snapshots` row
  for a sample of games.
- `playtime_session`, `family_share`, `wishlist_item` — open/close pattern:
  a tick either starts a new row (nullable end column left null) or closes
  an existing open one (end column set).
- `review` — writes a `reviews` row for a random (user, game) pair; a pair
  that's already reviewed is skipped rather than stored twice
  (`unique(user_id, game_id)`).

Start/stop is manual, not scheduled: leave it off between dev sessions to
keep the environment in the ~$0-3/month band.

## Throughput

Tick interval is calibrated (#16) to `TICK_MIN_SECONDS=1` /
`TICK_MAX_SECONDS=2`, landing combined event-table throughput (row inserts
across `purchases`, `gifts`, `key_redemptions`, `refunds`, `price_changes`,
`concurrent_player_snapshots`, `playtime_sessions`, `family_shares`,
`wishlist_items`, `reviews`) at ~1-3 events/sec, matching the ~50k
registered / ~5k DAU / ~500-1,000 peak-concurrent targets. Measured against
the live instance over a 2-minute window: 188 rows / 120s = **1.56
events/sec**. `concurrent_player_snapshot` dominates the count (25 rows per
tick, one row per sampled game) — a full 3,000-game sweep takes ~120
snapshot ticks, i.e. a few minutes of wall-clock at this interval, not
instantaneous.

Re-measure after changing `tick_min_seconds`/`tick_max_seconds` in
`terraform/generator.tf` or `EVENT_WEIGHTS` in `generator/generator.py`:
open the tunnel (`docs/rds-bootstrap.md`), sum row counts across the event
tables above, wait N seconds, sum again, and divide the delta by N.

```sql
select
  (select count(*) from purchases) + (select count(*) from gifts) +
  (select count(*) from key_redemptions) + (select count(*) from refunds) +
  (select count(*) from price_changes) +
  (select count(*) from concurrent_player_snapshots) +
  (select count(*) from playtime_sessions) + (select count(*) from family_shares) +
  (select count(*) from wishlist_items) + (select count(*) from reviews);
```

## Seed before first run

The generator writes purchases against existing users/games — it does not
create them. Run `generator/seed.py` once against a fresh database (after
the schema is applied, see `docs/rds-bootstrap.md`) before starting the
generator, or purchase ticks will find empty `users`/`games` tables.

## Start

```bash
cd terraform
INSTANCE_ID=$(tofu output -raw generator_instance_id)
aws ec2 start-instances --instance-ids "$INSTANCE_ID"
```

Docker and the container start automatically on boot (`--restart unless-stopped`).

## Watch the heartbeat

```bash
aws ssm start-session --target "$INSTANCE_ID"
# on the instance:
docker logs -f steam-generator
```

## Stop

```bash
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
```

## Also stop RDS between sessions

The generator EC2 instance (t4g.micro) and RDS (db.t4g.micro) are the two
metered-by-the-hour resources; both keep costing while running even with no
traffic. RDS supports the same stop/start cycle as EC2 (auto-restarts after
7 days if left stopped):

```bash
cd terraform
DB_ID=$(aws rds describe-db-instances --query 'DBInstances[0].DBInstanceIdentifier' --output text)
aws rds stop-db-instance --db-instance-identifier "$DB_ID"
# ...next session:
aws rds start-db-instance --db-instance-identifier "$DB_ID"
```

Stopped, the only ongoing charge is storage (RDS gp3 + EC2 root volumes,
well under $1/month combined) — comfortably inside the $0-3/month band.
Running 24/7, EC2 + RDS on-demand hourly rates alone land past $15/month, so
stop-when-idle (or `tofu destroy` for a full reset, see
`docs/rds-bootstrap.md`) is the cost control, not a scheduler — no cron is
introduced.

## First boot after `tofu apply`

The container is built and started by user data on first boot — allow a
minute or two for `dnf install docker` + `docker build` before logs appear.

If the generator instance is created in the same `tofu apply` as a fresh
RDS instance (rather than after schema/seed already exist, as
`scripts/bootstrap.sh` orders it), it starts ticking against empty
`users`/`games` tables — `purchase`/`playtime_session`/etc ticks throw on
the empty `select ... order by random() limit 1` and the container
crash-loops (`--restart unless-stopped` keeps retrying) until seed data
lands. Self-healing, but noisy. Use the script, or apply RDS+seed before
the generator exists, to avoid it.
