#!/usr/bin/env bash
# Static check on the Airflow Helm values split (no cluster needed).
#
#   1. every environment's base + overlay + image stack renders
#   2. the base alone renders and leaks nothing environment-specific
#
# (2) is the thing that rots silently: the base/overlay split exists so two
# environments cannot drift, and a value put in the base by mistake is
# invisible until both environments inherit the wrong one. Run it after
# touching anything under k8s/airflow/.
#
# Usage: bash scripts/check-airflow-values.sh
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALUES_DIR="$REPO_ROOT/k8s/airflow"

# Same chart version the ArgoCD Application pins, read from it rather than
# duplicated here, so a chart bump can't leave this check behind.
CHART_VERSION=$(awk '/chart: airflow$/{getline; print $2}' "$REPO_ROOT/argocd/apps/airflow.yaml")
[[ -n $CHART_VERSION ]] || { echo "FAIL: no chart version in argocd/apps/airflow.yaml" >&2; exit 1; }

# Values that identify one environment -- a match in the base-only render
# means the base is deciding something an overlay should. These are what
# set an environment: the Snowflake identity it runs as, the dbt target it
# builds, and the ALB path/rule-order it is served at. (`/airflow` on its own
# is not a usable token -- the chart's own paths are full of /opt/airflow.)
ENV_SPECIFIC='STEAM_PROD|STEAM_STAGING|STEAM_DEV|TRANSFORMER_|DBT_TARGET|COMPUTE_WH|SNOWFLAKE_|group\.order|base_url|path: /airflow'

helm repo add apache-airflow https://airflow.apache.org >/dev/null 2>&1 || true

render() { helm template airflow apache-airflow/airflow --version "$CHART_VERSION" --namespace airflow "$@"; }

status=0

for overlay in "$VALUES_DIR"/values-*.yaml; do
  case $(basename "$overlay") in values-image-*) continue ;; esac
  env_name=$(basename "$overlay" .yaml); env_name=${env_name#values-}
  image="$VALUES_DIR/values-image-$env_name.yaml"
  [[ -f $image ]] || { echo "FAIL: $env_name has no values-image-$env_name.yaml"; status=1; continue; }
  if render -f "$VALUES_DIR/values.yaml" -f "$overlay" -f "$image" >/dev/null; then
    echo "ok    $env_name renders (values.yaml + $(basename "$overlay") + $(basename "$image"))"
  else
    echo "FAIL  $env_name does not render"; status=1
  fi
done

leaked=$(render -f "$VALUES_DIR/values.yaml" | grep -nEi "$ENV_SPECIFIC" || true)
if [[ -z $leaked ]]; then
  echo "ok    base values alone leak nothing environment-specific"
else
  echo "FAIL  base values leak environment-specific values:"; echo "$leaked"; status=1
fi

exit "$status"
