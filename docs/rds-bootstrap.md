# RDS bootstrap cheat sheet

Run after every `tofu apply` from a clean state (i.e. after `tofu destroy`). The schema is not applied automatically — this is the manual step.

## Automated (recommended)

```bash
./scripts/bootstrap.sh
```

Runs the whole flow below end to end: applies RDS + bastion first, opens
the SSM tunnel, applies `db/schema.sql`, runs `generator/seed.py`, closes
the tunnel, then applies the generator instance *last* — so it never boots
against an empty database. See `docs/generator-runbook.md` for why that
ordering matters. Use the manual steps below to debug a stuck tunnel or
rerun a single piece by hand.

## 1. Provision

```bash
cd terraform
tofu init
tofu apply
```

## 2. Open the tunnel (terminal 1, leave running)

```bash
cd terraform
INSTANCE_ID=$(tofu output -raw bastion_instance_id)
RDS_HOST=$(tofu output -raw rds_endpoint)
aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "{\"host\":[\"$RDS_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

Wait for `Waiting for connections...`.

## 3. Apply the schema (terminal 2)

```bash
cd terraform
PGPASSWORD=$(tofu output -raw db_password) psql -h localhost -p 15432 -U steam_proj_admin -d steam -f ../db/schema.sql
```

## 4. Verify

```bash
PGPASSWORD=$(tofu output -raw db_password) psql -h localhost -p 15432 -U steam_proj_admin -d steam -c '\dt'
```

Should list 15 tables, 0 rows each.

## Interactive session

```bash
PGPASSWORD=$(tofu output -raw db_password) psql -h localhost -p 15432 -U steam_proj_admin -d steam
```

`\dt` tables, `\d <table>` columns, `\q` quit.

## Done — close the tunnel

Ctrl+C in terminal 1.

## Tear down

```bash
tofu destroy
```

Destroys everything. No retention logic — this is the intended reset. Next `tofu apply` needs steps 2-4 repeated; `db_password` regenerates, `steam_proj_admin` username stays fixed.
