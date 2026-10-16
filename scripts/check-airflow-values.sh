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
# `rules` holds "PATH ORDER ENV" so the overlap check can compare both.
orders=() rules=() schemes=() group_names=() chart_versions=() releases=()

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

  if ! rendered=$(render "$release" "$chart_version" "$namespace" \
    -f "$VALUES_DIR/values.yaml" -f "$overlay" -f "$image"); then
    echo "FAIL  $env_name does not render"; status=1; continue
  fi
  # Appended *after* the render, with the other three, so an environment that
  # fails to render contributes to none of the cross-checks rather than one.
  chart_versions+=("$chart_version")
  releases+=("$release")
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
  # Bare integer for the comparisons below; the annotation renders quoted.
  order_n=$(grep -oE 'group\.order: "?-?[0-9]+"?' <<<"$ingress" | head -1 | grep -oE '\-?[0-9]+' || true)
  orders+=("${order:-<none>}")
  rules+=("${path:-<none>} ${order_n:-<none>} $env_name")
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

  # #125: AIRFLOW__API__BASE_URL mounts the *entire* FastAPI app -- including
  # the task execution API -- under that prefix, but execution_api_server_url
  # does not pick the prefix up on its own (it is a separate setting, and the
  # chart default is unprefixed). Every container carries both env vars
  # identically, so the first match is the whole render's answer. This caught
  # #125 for real: workers PATCHed /execution/... while the api-server only
  # served /airflow/execution/..., and every task failed instantly with
  # ServerResponseError: Not Found -- invisible to the Ingress checks above,
  # to ArgoCD health, and to pod readiness, because the api-server itself
  # comes up fine either way.
  # `|| true` on each pipeline: a missing env var (the exact regression this
  # check exists to catch) makes the `grep -oE` match nothing and exit 1,
  # and under `set -o pipefail` that would abort the whole script right here
  # -- skipping this environment's own FAIL message below and every check
  # after it, silently. The diagnostic lives in the if/elif below instead.
  base_url=$(awk '/name: AIRFLOW__API__BASE_URL/{getline; print; exit}' <<<"$rendered" | grep -oE '/\S+' | tr -d '"' || true)
  exec_url=$(awk '/name: AIRFLOW__CORE__EXECUTION_API_SERVER_URL/{getline; print; exit}' <<<"$rendered" | grep -oE 'http\S+' | tr -d '"' || true)
  exec_path=$(grep -oE '^https?://[^/]+(/.*)$' <<<"$exec_url" | sed -E 's#^https?://[^/]+##' || true)
  if [[ -z $base_url || -z $exec_url ]]; then
    echo "FAIL  $env_name: could not read AIRFLOW__API__BASE_URL and/or AIRFLOW__CORE__EXECUTION_API_SERVER_URL from the render"
    status=1
  elif [[ $exec_path != "$base_url"* ]]; then
    echo "FAIL  $env_name's execution_api_server_url path ('$exec_path') does not start with its base_url ('$base_url') -- workers will PATCH the unprefixed path while the api-server serves it under the prefix, and every task fails with ServerResponseError: Not Found (#125)"
    status=1
  else
    echo "ok    $env_name's execution_api_server_url ($exec_url) is prefixed with its base_url ($base_url)"
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

# prefix_orders_correct — for every ordered pair of rules where one path is a
# `pathType: Prefix` prefix of the other, assert the longer path has the lower
# group.order. Reads the "PATH ORDER ENV" rows in $rules.
#
# Pairwise rather than a sort, because only *overlapping* paths constrain each
# other: /argocd and /airflow may be in any order, and demanding a global
# longest-first ordering would reject a perfectly good configuration.
prefix_orders_correct() {
  local a b pa oa ea pb ob eb checked=0
  for a in "${rules[@]}"; do
    read -r pa oa ea <<<"$a"
    for b in "${rules[@]}"; do
      read -r pb ob eb <<<"$b"
      # Only pairs where b's path extends a's, so each pair is seen once.
      [[ $ea != "$eb" && $pb == "$pa"* && $pb != "$pa" ]] || continue
      checked=$((checked + 1))
      if [[ $oa == "<none>" || $ob == "<none>" ]]; then
        echo "FAIL  $pa ($ea) and $pb ($eb) overlap but one has no group.order"; status=1
      elif (( ob < oa )); then
        echo "ok    $pb ($eb, order $ob) is evaluated before $pa ($ea, order $oa)"
      else
        echo "FAIL  $pa ($ea) has group.order $oa and $pb ($eb) has $ob -- $pa is a prefix of $pb and lower is evaluated first, so $ea's rule swallows every $pb request. $eb must take the lower order."
        status=1
      fi
    done
  done
  (( checked )) || echo "ok    no two environments' paths overlap"
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
  # Equal orders are resolved by a lexicographic namespace/name tie-break --
  # not something to leave two overlapping prefixes to.
  all_distinct "group.order" "${orders[@]}"
  # And the assertion that actually matters. Distinctness is only a proxy: it
  # passes just as happily with the orders the wrong way round, which is the
  # failure the annotation exists to prevent (prod's /airflow rule matching
  # every /airflow-staging request, so staging's URL serves prod's Airflow).
  # The real invariant is that where one path is a prefix of another, the
  # *longer* one must be evaluated first, i.e. carry the lower order.
  prefix_orders_correct
  # Staging exists to be prod-like; two chart versions is two Airflows.
  all_same "the chart version" "${chart_versions[@]}"
fi

# The other direction of the k8s/airflow <-> lib/env.sh relationship. Above,
# each overlay is required to have an Application; here, every environment
# that renders is required to be in AIRFLOW_ENVIRONMENTS — which is what
# bring-up walks to create the namespace and its Secrets, to populate
# EXPECTED_APPS and to health-check the Deployments.
#
# Without this, an overlay + image file + Application added without touching
# env.sh passes every check above, is skipped by all of bring-up, is never
# waited for, and bring-up reports success while that environment's pods sit
# in CreateContainerConfigError for want of Secrets nobody created.
if (( ${#releases[@]} )); then
  # shellcheck source=scripts/lib/env.sh
  source "$REPO_ROOT/scripts/lib/env.sh"
  undeclared=$(comm -23 <(printf '%s\n' "${releases[@]}" | sort) \
    <(printf '%s\n' "${AIRFLOW_ENVIRONMENTS[@]}" | sort))
  unbuilt=$(comm -13 <(printf '%s\n' "${releases[@]}" | sort) \
    <(printf '%s\n' "${AIRFLOW_ENVIRONMENTS[@]}" | sort))
  if [[ -z $undeclared && -z $unbuilt ]]; then
    echo "ok    lib/env.sh's AIRFLOW_ENVIRONMENTS matches the Applications (${AIRFLOW_ENVIRONMENTS[*]})"
  else
    [[ -z $undeclared ]] || { echo "FAIL  deployed but not in lib/env.sh's AIRFLOW_ENVIRONMENTS, so bring-up creates no namespace or Secrets for it: $(tr '\n' ' ' <<<"$undeclared")"; status=1; }
    [[ -z $unbuilt ]] || { echo "FAIL  in lib/env.sh's AIRFLOW_ENVIRONMENTS but has no values overlay or Application: $(tr '\n' ' ' <<<"$unbuilt")"; status=1; }
  fi
fi

# Rendered into a variable first rather than piped straight into grep: with
# `|| true` on the pipeline, a helm failure would leave $leaked empty and this
# would report "leaks nothing" having rendered nothing at all.
# --- the base alone -------------------------------------------------------
#
# Rendered at the environments' pinned chart version. Guarded rather than
# defaulted: `helm template --version ""` silently resolves the *newest* chart
# in the repo, so an empty value here would mean reporting "the base leaks
# nothing" about a chart nobody pinned.
if (( ${#chart_versions[@]} == 0 )); then
  echo "FAIL  no environment yielded a chart version, so the base cannot be rendered at the pinned one"
  exit 1
fi
if ! base_render=$(render airflow "${chart_versions[0]}" airflow -f "$VALUES_DIR/values.yaml"); then
  echo "FAIL  base values alone do not render"
  exit 1
fi
leaked=$(grep -nEi "$ENV_SPECIFIC" <<<"$base_render" || true)
if [[ -z $leaked ]]; then
  echo "ok    base values alone leak nothing environment-specific"
else
  echo "FAIL  base values leak environment-specific values:"; echo "$leaked"; status=1
fi

# --- #123: the chart's generated Secrets must actually be gone ------------
#
# Three of them (fernet key, redis password, the redis connection/broker
# URL) are rendered as "helm.sh/hook": "pre-install" -- ArgoCD translates
# that to a PreSync hook recreated on every sync, and with two Airflow
# releases the second one's hook-completion wait never resolved (#123's
# bring-up symptom: "waiting for completion of hook /Secret/.../-broker-url
# and 2 more hooks", forever). Checked on the *per-environment* render
# (base + overlay + image), not the base alone: a chart template is gated on
# whether a values *overlay* leaves the matching *SecretName unset, so the
# base rendering clean proves nothing about what a real release gets.
#
# This is the assertion #122's invariant is aimed at: it must be possible to
# see it fail. Prove that to yourself by reverting the five *SecretName
# lines this ticket added to values.yaml and re-running this script -- the
# hook annotation reappears and this block reports FAIL, twice (once per
# environment), which is also why it is a loop over every rendered stack
# rather than a single check on the first one.
if (( ${#releases[@]} )); then
  i=0
  for overlay in "$VALUES_DIR"/values-*.yaml; do
    case $(basename "$overlay") in values-image-*) continue ;; esac
    env_name=$(basename "$overlay" .yaml); env_name=${env_name#values-}
    image="$VALUES_DIR/values-image-$env_name.yaml"
    [[ -f $image ]] || continue
    app=$(app_for "$env_name")
    [[ -n $app && $app != *$'\n'* ]] || continue
    release="${releases[$i]:-}"
    namespace=$(awk '/^  destination:/{f=1} f && /^    namespace:/{print $2; exit}' "$app")
    chart_version=$(chart_version_of "$app")
    i=$((i + 1))
    [[ -n $release && -n $namespace && -n $chart_version ]] || continue
    full_render=$(render "$release" "$chart_version" "$namespace" \
      -f "$VALUES_DIR/values.yaml" -f "$overlay" -f "$image") || continue
    hooked=$(grep -n 'pre-install' <<<"$full_render" | grep -v '^[0-9]*:#' || true)
    if [[ -n $hooked ]]; then
      echo "FAIL  $env_name's render still carries a pre-install hook -- a chart-generated Secret is not pinned:"; echo "$hooked"; status=1
    else
      echo "ok    $env_name's render carries no pre-install hook"
    fi
  done
fi

# Every *SecretName (and redis.passwordSecretName / data.brokerUrlSecretName)
# the base sets must be a Secret bring-up actually creates
# (scripts/bringup/stages/05-cluster.sh) -- otherwise pinning the name in
# values.yaml only trades "ArgoCD waits on a hook forever" for "the Secret
# the chart no longer generates doesn't exist either", and the pods that
# need it sit in CreateContainerConfigError instead.
base_secret_names=$(grep -oE '^[A-Za-z]*SecretName: \S+' "$VALUES_DIR/values.yaml" | awk '{print $2}')
base_secret_names+=$'\n'$(grep -oE '^  (passwordSecretName|brokerUrlSecretName): \S+' "$VALUES_DIR/values.yaml" | awk '{print $2}')
base_secret_names=$(grep -v '^$' <<<"$base_secret_names" || true)
if [[ -z $base_secret_names ]]; then
  echo "FAIL  found no *SecretName pins in values.yaml to check against bring-up -- did the grep pattern stop matching?"
  status=1
else
  bringup_file="$REPO_ROOT/scripts/bringup/stages/05-cluster.sh"
  while read -r name; do
    [[ -n $name ]] || continue
    if grep -q "kubectl create secret generic $name " "$bringup_file"; then
      echo "ok    $name (pinned in values.yaml) is created by $(basename "$bringup_file")"
    else
      echo "FAIL  values.yaml pins a Secret name '$name' that $(basename "$bringup_file") never creates"
      status=1
    fi
  done <<<"$base_secret_names"
fi

exit "$status"
