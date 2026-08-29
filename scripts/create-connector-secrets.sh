#!/bin/bash
# Wire the RDS connecting-user credentials and the Snowflake RSA key pair
# into k8s Secrets in the `kafka` namespace, for #44 (Debezium source
# connector) and #45 (Snowflake sink connector) to reference by name.
#
# Like ecr-registry-credentials (k8s/kafka/kafka-connect.yaml), these are
# regenerated per session, not stored in git — the `kafka` namespace itself
# doesn't survive `tofu destroy`, so there's nothing to persist across
# sessions except the source material.
#
# Prerequisites:
#   - EKS cluster + Strimzi operator applied (terraform/eks.tf, strimzi.tf),
#     kubectl context pointed at it: aws eks update-kubeconfig --name steam-infra
#   - Snowflake RSA key pair generated at .secrets/snowflake_key.p8, and its
#     public half already registered on the Snowflake user:
#       openssl genpkey -algorithm RSA -out .secrets/snowflake_key.p8 -pkeyopt rsa_keygen_bits:2048
#       openssl rsa -in .secrets/snowflake_key.p8 -pubout -out .secrets/snowflake_key.pub
#       -- then in a Snowflake worksheet --
#       ALTER USER <user> SET RSA_PUBLIC_KEY='<contents of .pub, header/footer/newlines stripped>';
#     Only needs doing once — re-running this script does NOT regenerate
#     the key pair (that would desync it from what's registered in Snowflake).
set -euo pipefail

cd "$(dirname "$0")/.."

KEY_FILE=.secrets/snowflake_key.p8
if [ ! -f "$KEY_FILE" ]; then
  echo "missing $KEY_FILE — generate the Snowflake key pair and register it first (see script header)" >&2
  exit 1
fi

echo "==> rds-credentials"
DB_PASSWORD=$(cd terraform && tofu output -raw db_password)
kubectl create secret generic rds-credentials -n kafka \
  --from-literal=username=steam_proj_admin \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> snowflake-keypair"
# snowflake.private.key expects the base64 body only, no PEM header/footer/newlines.
PRIVATE_KEY_STRIPPED=$(grep -v '^-----' "$KEY_FILE" | tr -d '\n')
kubectl create secret generic snowflake-keypair -n kafka \
  --from-literal=private_key="$PRIVATE_KEY_STRIPPED" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> done"
