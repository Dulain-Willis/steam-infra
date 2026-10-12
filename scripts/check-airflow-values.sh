#!/usr/bin/env bash
# Static check on the Airflow Helm values split (no cluster needed).
#
#   1. every environment's base + overlay + image stack renders, and its
#      Ingress claims its own path with an explicit rule order
#   2. the base alone renders and leaks nothing environment-specific
#
# (2) is the thing that rots silently: the base/overlay split exists so two
# environments cannot drift, and a value put in the base by mistake is
# invisible until both environments inherit the wrong one.
#
# The Ingress half of (1) guards the other direction. `path` and `group.order`
# are *only* in the overlay now, so an overlay that forgets them renders an
# Ingress claiming `/` at order 0 on the shared internal ALB -- which would
# swallow /argocd and every other member's rule rather than failing. Run this
# after touching anything under k8s/airflow/.
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
# It is a denylist, so it only catches values someone thought of: add to it in
# the same commit that adds a new kind of environment-specific value.
ENV_SPECIFIC='STEAM_PROD|STEAM_STAGING|STEAM_DEV|TRANSFORMER_|DBT_TARGET|COMPUTE_WH|SNOWFLAKE_|group\.order|base_url|path: /airflow'

# --force-update because plain `repo add` on an existing repo errors and leaves
# the cached index alone -- an index older than the pinned chart version then
# fails the render with "chart not found", which reads like a values problem.
helm repo add --force-update apache-airflow https://airflow.apache.org >/dev/null

render() { helm template airflow apache-airflow/airflow --version "$CHART_VERSION" --namespace airflow "$@"; }

status=0

for overlay in "$VALUES_DIR"/values-*.yaml; do
  case $(basename "$overlay") in values-image-*) continue ;; esac
  env_name=$(basename "$overlay" .yaml); env_name=${env_name#values-}
  image="$VALUES_DIR/values-image-$env_name.yaml"
  [[ -f $image ]] || { echo "FAIL: $env_name has no values-image-$env_name.yaml"; status=1; continue; }
  if ! rendered=$(render -f "$VALUES_DIR/values.yaml" -f "$overlay" -f "$image"); then
    echo "FAIL  $env_name does not render"; status=1; continue
  fi
  echo "ok    $env_name renders (values.yaml + $(basename "$overlay") + $(basename "$image"))"

  # First Ingress document only -- a plain range pattern re-triggers per
  # document and would concatenate a second one into the same block, after
  # which the single path/order read below silently describes only the first.
  ingress=$(awk '/^kind: Ingress$/{f=1} f; f && /^---$/{exit}' <<<"$rendered")
  # Anchored on indentation so this reads spec.rules[].http.paths[].path and not
  # an annotation key that happens to end in `-path` (healthcheck-path is a
  # normal thing to add when serving under a prefix, and annotations render
  # above spec). `|| true` on both: a missing value is what is being checked,
  # not a reason to abort under `set -e` having printed nothing.
  path=$(awk '/^ +path: \//{print $2; exit}' <<<"$ingress" || true)
  order=$(grep -oE 'group\.order: "?-?[0-9]+"?' <<<"$ingress" | head -1 || true)
  if [[ -z $ingress ]]; then
    echo "FAIL  $env_name renders no Ingress -- the overlay must set ingress.apiServer.enabled and path"; status=1
  elif [[ $path == "/" || -z $path ]]; then
    echo "FAIL  $env_name's Ingress claims path '$path' -- the overlay must set ingress.apiServer.path"; status=1
  elif [[ -z $order ]]; then
    echo "FAIL  $env_name's Ingress has no alb.ingress.kubernetes.io/group.order ($path overlaps other members at the default order 0)"; status=1
  else
    echo "ok    $env_name's Ingress: $path, $order"
  fi
done

# Rendered into a variable first rather than piped straight into grep: with
# `|| true` on the pipeline, a helm failure would leave $leaked empty and this
# would report "leaks nothing" having rendered nothing at all.
if ! base_render=$(render -f "$VALUES_DIR/values.yaml"); then
  echo "FAIL  base values alone do not render"
  exit 1
fi
leaked=$(grep -nEi "$ENV_SPECIFIC" <<<"$base_render" || true)
if [[ -z $leaked ]]; then
  echo "ok    base values alone leak nothing environment-specific"
else
  echo "FAIL  base values leak environment-specific values:"; echo "$leaked"; status=1
fi

exit "$status"
