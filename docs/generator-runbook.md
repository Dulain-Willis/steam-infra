# Generator runbook

The generator EC2 instance runs a Docker container that ticks against
Postgres over the private VPC on a jittered interval, picking an event
type by weight and writing the corresponding rows. Registered event
types, all feeding the same `ownership_grants` fan-in:

- `purchase` — writes a `purchases` row and the fan-in `ownership_grants` row.
- `gift` — two-phase: sends a new `gifts` row (`redeemed_at` null), or
  redeems an existing unredeemed one, writing the fan-in
  `ownership_grants` row only at redemption time.
- `key_redemption` — writes a `key_redemptions` row and the fan-in
  `ownership_grants` row.
- `refund` — writes a `refunds` row against an existing purchase and sets
  `revoked_at` on the matching `ownership_grants` row (never deletes or
  duplicates it).
- `price_change` — nudges a random seeded `game_prices` row and writes the
  `price_changes` audit row.
- `concurrent_player_snapshot` — writes a `concurrent_player_snapshots`
  row for a sampled batch of games.

Start/stop is manual, not scheduled: leave it off between dev sessions to
keep the environment in the ~$0-3/month band.

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

## First boot after `tofu apply`

The container is built and started by user data on first boot — allow a
minute or two for `dnf install docker` + `docker build` before logs appear.
