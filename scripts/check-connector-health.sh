#!/bin/bash
# Verify the Debezium source and Snowflake sink connectors + all their
# tasks are RUNNING, via the Kafka Connect REST API (#46). Fast/cheap
# signal, checked before any data-correctness check — a broken deploy
# (bad credentials, missing plugin, RDS unreachable) shows up here in
# seconds without waiting on data flow. REST API only, no topic/pod
# inspection.
set -euo pipefail

CONNECT_POD="steam-infra-connect-0"
NAMESPACE="kafka"
CONNECTORS=(debezium-postgres-source snowflake-sink)

fail=0

for connector in "${CONNECTORS[@]}"; do
  echo "==> checking $connector"

  status=$(kubectl exec -n "$NAMESPACE" "$CONNECT_POD" -- \
    curl -s -w '\n%{http_code}' "localhost:8083/connectors/$connector/status")
  http_code=$(echo "$status" | tail -n1)
  body=$(echo "$status" | sed '$d')

  if [ "$http_code" != "200" ]; then
    echo "FAIL: $connector — Connect REST API returned $http_code: $body" >&2
    fail=1
    continue
  fi

  connector_state=$(echo "$body" | jq -r '.connector.state')
  if [ "$connector_state" != "RUNNING" ]; then
    echo "FAIL: $connector — connector state is $connector_state, expected RUNNING" >&2
    fail=1
    continue
  fi

  task_states=$(echo "$body" | jq -r '.tasks[] | "\(.id):\(.state)"')
  bad_tasks=$(echo "$task_states" | grep -v ':RUNNING$' || true)
  if [ -n "$bad_tasks" ]; then
    echo "FAIL: $connector — task(s) not RUNNING:" >&2
    echo "$bad_tasks" >&2
    fail=1
    continue
  fi

  task_count=$(echo "$body" | jq '.tasks | length')
  echo "OK: $connector — connector RUNNING, $task_count task(s) RUNNING"
done

if [ "$fail" != "0" ]; then
  echo "==> one or more connectors unhealthy" >&2
  exit 1
fi

echo "==> all connectors healthy"
