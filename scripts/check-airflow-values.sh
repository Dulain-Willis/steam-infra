#!/usr/bin/env bash
# Static check on the Airflow Helm values split (no cluster needed).
#
#   1. every environment's base + overlay + image stack renders, and its
#      Ingress claims its own path with an explicit rule order
#   2. the base alone renders and leaks nothing environment-specific
#   3. the environments agree where the shared ALB requires it and differ
#      where it requires that instead
#
# (2) is the thing that rots silently: the base/overlay split exists so two
# environments cannot drift, and a value put in the base by mistake is
# invisible until both environments inherit the wrong one.
#
# The Ingress half of (1) guards the other direction. `path` and `group.order`
# are *only* in the overlay now, so an overlay that forgets them renders an
# Ingress claiming `/` at order 0 on the shared internal ALB -- which would
# swallow /argocd and every other member's rule rather than failing.
#
# (3) is the pair of IngressGroup rules that bite everyone rather than the
# environment with the mistake: two members at the same `group.order` have
# their overlapping prefixes resolved by a lexicographic tie-break, and two
# members disagreeing on an *exclusive* annotation (`scheme` and friends) stop
# the whole group reconciling for every member. Run this after touching
# anything under k8s/airflow/ or argocd/apps/airflow*.yaml.
#
# Usage: bash scripts/check-airflow-values.sh
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALUES_DIR="$REPO_ROOT/k8s/airflow"

# app_for ENV — the ArgoCD Application that deploys this overlay, found by
# which one references the overlay rather than by filename convention. So an
# overlay nothing deploys fails here instead of looking fine and being dead.
app_for() { grep -ls "values-$1\.yaml" "$REPO_ROOT"/argocd/apps/*.yaml || true; }

# The `targetRevision:` *after* `chart: airflow`, not simply the line after
# it: an Application has two targetRevision lines (chart version and git ref)
# and a comment may sit between the chart and its version, either of which
# would otherwise be returned as the chart version.
chart_version_of() {
  awk '/chart: airflow$/{f=1} f && /targetRevision:/{print $2; exit}' "$1"
}

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

render() { helm template "$1" apache-airflow/airflow --version "$2" --namespace "$3" "${@:4}"; }

status=0
# Collected per environment for the cross-environment assertions at the end.
orders=() schemes=() group_names=() chart_versions=()

for overlay in "$VALUES_DIR"/values-*.yaml; do
  case $(basename "$overlay") in values-image-*) continue ;; esac
  env_name=$(basename "$overlay" .yaml); env_name=${env_name#values-}
  image="$VALUES_DIR/values-image-$env_name.yaml"
  [[ -f $image ]] || { echo "FAIL: $env_name has no values-image-$env_name.yaml"; status=1; continue; }

  # The Application name is the Helm release name and its destination is the
  # namespace, so rendering with those is what the cluster actually gets --
  # the chart names half its resources after the release.
  app=$(app_for "$env_name")
  if [[ -z $app || $app == *$'\n'* ]]; then
    echo "FAIL  $env_name: expected exactly one argocd/apps Application referencing values-$env_name.yaml, found: ${app:-none}"
    status=1; continue
  fi
  release=$(awk '/^metadata:/{f=1} f && /^  name:/{print $2; exit}' "$app")
  namespace=$(awk '/^  destination:/{f=1} f && /^    namespace:/{print $2; exit}' "$app")
  chart_version=$(chart_version_of "$app")
  if [[ -z $release || -z $namespace || -z $chart_version ]]; then
    echo "FAIL  $env_name: could not read name/namespace/chart version from $(basename "$app")"
    status=1; continue
  fi
  chart_versions+=("$chart_version")

  if ! rendered=$(render "$release" "$chart_version" "$namespace" \
    -f "$VALUES_DIR/values.yaml" -f "$overlay" -f "$image"); then
    echo "FAIL  $env_name does not render"; status=1; continue
  fi
  echo "ok    $env_name renders as release $release in namespace $namespace (values.yaml + $(basename "$overlay") + $(basename "$image"))"

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
  orders+=("${order:-<none>}")
  schemes+=("$(grep -oE 'scheme: \S+' <<<"$ingress" | head -1 || true)")
  group_names+=("$(grep -oE 'group\.name: \S+' <<<"$ingress" | head -1 || true)")
  if [[ -z $ingress ]]; then
    echo "FAIL  $env_name renders no Ingress -- the overlay must set ingress.apiServer.enabled and path"; status=1
  elif [[ $path == "/" || -z $path ]]; then
    echo "FAIL  $env_name's Ingress claims path '$path' -- the overlay must set ingress.apiServer.path"; status=1
  elif [[ -z $order ]]; then
    echo "FAIL  $env_name's Ingress has no alb.ingress.kubernetes.io/group.order ($path overlaps other members at the default order 0)"; status=1
  elif [[ $path != "/$release" ]]; then
    # lib/env.sh's AIRFLOW_ENVIRONMENTS treats the Application name as the URL
    # prefix too, which is how bring-up prints working links and waits on the
    # right Ingress without a second list. Asserted here so that convention
    # cannot quietly stop holding.
    echo "FAIL  $env_name's Ingress claims $path but its release is $release -- bring-up prints /$release (scripts/lib/env.sh AIRFLOW_ENVIRONMENTS)"; status=1
  else
    echo "ok    $env_name's Ingress: $path, $order"
  fi
done

# --- the shared-ALB and prod-likeness invariants across environments --------
#
# Each of these is a mistake whose blast radius is bigger than the environment
# that made it, which is why they are asserted here rather than left to the
# first person who opens a URL.

# all_same WHAT VALUE... / all_distinct WHAT VALUE... — one line per rule,
# printing the values either way so a failure says what disagreed.
all_same() {
  local what="$1" distinct
  distinct=$(printf '%s\n' "${@:2}" | sort -u | wc -l | tr -d ' ')
  if [[ $distinct == 1 ]]; then
    echo "ok    every environment agrees on $what (${2})"
  else
    echo "FAIL  environments disagree on $what: ${*:2}"; status=1
  fi
}

all_distinct() {
  local what="$1" distinct
  distinct=$(printf '%s\n' "${@:2}" | sort -u | wc -l | tr -d ' ')
  if [[ $distinct == $(( $# - 1 )) ]]; then
    echo "ok    every environment has its own $what (${*:2})"
  else
    echo "FAIL  two environments share a $what: ${*:2}"; status=1
  fi
}

if (( ${#orders[@]} > 1 )); then
  # Exclusive IngressGroup annotations: a member that disagrees stops the
  # *whole* group reconciling, so no member gets updated. `scheme` is the one
  # this repo sets; it lives in values.yaml for exactly this reason, and this
  # asserts the render bears that out rather than trusting the file layout.
  all_same "the ALB scheme" "${schemes[@]}"
  all_same "the ALB group.name" "${group_names[@]}"
  # /airflow is a prefix of /airflow-staging, so the rules overlap and the
  # order decides which wins. Equal orders are resolved by a lexicographic
  # namespace/name tie-break -- not something to leave two overlapping
  # prefixes to.
  all_distinct "group.order" "${orders[@]}"
  # Staging exists to be prod-like; two chart versions is two Airflows.
  all_same "the chart version" "${chart_versions[@]}"
fi

# Rendered into a variable first rather than piped straight into grep: with
# `|| true` on the pipeline, a helm failure would leave $leaked empty and this
# would report "leaks nothing" having rendered nothing at all.
if ! base_render=$(render airflow "${chart_versions[0]:-}" airflow -f "$VALUES_DIR/values.yaml"); then
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
