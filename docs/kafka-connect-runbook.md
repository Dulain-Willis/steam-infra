# Kafka Connect / Debezium connector runbook

Bring-up order for the CDC layer (EKS + Strimzi + Kafka + Connect +
connectors), on top of an already-applied RDS (`scripts/bootstrap.sh`,
`docs/rds-bootstrap.md`). Everything here is applied via `kubectl`, not
Terraform, per the IaC boundary (#28) — Terraform only owns EKS + the
Strimzi operator install (`terraform/eks.tf`, `terraform/strimzi.tf`).

## 1. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --name steam-infra
```

## 2. RDS prerequisites

```bash
./scripts/check-rds-prereqs.sh
```

Verifies `rds.logical_replication=1` is actually in effect and
`steam_proj_admin` has `rds_replication` + `SELECT` on all 14 tables. Fails
with the exact fix (e.g. the missing `GRANT`) rather than letting a bad
connector config look like a new bug.

## 3. Kafka cluster

```bash
kubectl apply -f k8s/kafka/kafka-cluster.yaml
kubectl wait kafka/steam-infra -n kafka --for=condition=Ready --timeout=300s
```

## 4. Kafka Connect (build + deploy)

```bash
cd terraform
ECR_REPO=$(tofu output -raw kafka_connect_ecr_repository_url)
cd ..

kubectl create secret docker-registry ecr-registry-credentials -n kafka \
  --docker-server="${ECR_REPO%%/*}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)" \
  --dry-run=client -o yaml | kubectl apply -f -

sed "s|<account-id>.dkr.ecr.us-east-1.amazonaws.com/steam-infra-kafka-connect|$ECR_REPO|" \
  k8s/kafka/kafka-connect.yaml | kubectl apply -f -

kubectl wait kafkaconnect/steam-infra -n kafka --for=condition=Ready --timeout=600s
```

The build step compiles a plugin image and pushes it to ECR — the ECR login
token expires after 12h, so the registry Secret is regenerated per session
rather than committed.

## 5. Connector secrets

```bash
./scripts/create-connector-secrets.sh
```

Wires `rds-credentials` and `snowflake-keypair` into the `kafka` namespace
(see script header for the one-time Snowflake key-pair setup).

## 6. Debezium source connector

```bash
cd terraform
RDS_HOST=$(tofu output -raw rds_endpoint)
cd ..

sed "s|<rds-endpoint>|$RDS_HOST|" k8s/kafka/debezium-connector.yaml | kubectl apply -f -
```

## 7. Snowflake sink connector

```bash
kubectl apply -f k8s/kafka/snowflake-connector.yaml
```

Consumes the 14 `steam.public.*` Debezium topics directly and writes to
Snowflake via Snowpipe — no S3 or other landing zone (#34, #45).

## 8. Verify

Both connectors + all tasks `RUNNING` via the Connect REST API (fast signal —
checks before any data has to flow):

```bash
kubectl exec -n kafka steam-infra-connect-0 -- \
  curl -s localhost:8083/connectors/debezium-postgres-source/status
kubectl exec -n kafka steam-infra-connect-0 -- \
  curl -s localhost:8083/connectors/snowflake-sink/status
```

Topics created for all 14 tables (`topic.prefix: steam` +
`schema.include.list: public`):

```bash
kubectl exec -n kafka steam-infra-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep ^steam\\.public\\.
```

Should list 14 topics, `steam.public.<table>` for each table in
`db/schema.sql`.

Snowflake tables receiving rows (each `steam.public.<table>` topic lands in
`STEAM_PROJECT.PUBLIC.<table>` per `snowflake.topic2table.map`):

```sql
select count(*) from steam_project.public.users;
```

## Teardown

Before `tofu destroy`, drop the replication slot Debezium created — it
isn't cleaned up automatically and pins WAL on the RDS instance otherwise
(`docs/debezium-postgres-config.md`):

```bash
PGPASSWORD=$(cd terraform && tofu output -raw db_password) \
  psql -h localhost -p 15432 -U steam_proj_admin -d steam \
  -c "select pg_drop_replication_slot('debezium_steam');"
```

(Open the SSM tunnel first — see `docs/rds-bootstrap.md` step 2.) The `kafka`
namespace itself doesn't survive `tofu destroy` (it lives on the EKS
cluster being destroyed), so nothing else needs explicit cleanup.
