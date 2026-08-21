# Generator runbook

The generator EC2 instance runs a Docker container that heartbeats against
Postgres over the private VPC. No table writes yet — this proves the
networking path and the start/stop model.

Start/stop is manual, not scheduled: leave it off between dev sessions to
keep the environment in the ~$0-3/month band.

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
