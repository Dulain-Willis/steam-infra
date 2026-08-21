# Generator runbook

The generator EC2 instance runs a Docker container that ticks against
Postgres over the private VPC on a jittered interval, picking an event
type by weight and writing the corresponding rows. Registered event types:

- `purchase` — writes a `purchases` row and the fan-in `ownership_grants` row.
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
