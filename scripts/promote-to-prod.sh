#!/usr/bin/env bash
# Promote an image tag into prod's Airflow values file. The file edit half of
# .github/workflows/promote-to-prod.yml -- the workflow does the git/PR half.
#
#   bash scripts/promote-to-prod.sh          # promote staging's current tag
#   bash scripts/promote-to-prod.sh <TAG>    # promote an older tag (rollback)
#
# Why a script rather than steps in the workflow: every branch here (no-op,
# unknown tag, malformed tag, missing file) is a branch that only ever runs
# when something is wrong, and a workflow can only be exercised by dispatching
# it against the real repo. `scripts/promote-to-prod-test.sh` runs all of them
# against throwaway git repos in a second. Same reason lib/grant_check.sh is a
# script with a test rather than inline bring-up steps.
#
# No yq: both image files are two keys and a comment block, the edit must
# change exactly one line (that is the PR's whole value to a reviewer), and a
# YAML round-trip is free to reflow the rest. awk on the one line cannot.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"

STAGING_REL="k8s/airflow/values-image-staging.yaml"
PROD_REL="k8s/airflow/values-image-prod.yaml"
STAGING="$REPO_ROOT/$STAGING_REL"
PROD="$REPO_ROOT/$PROD_REL"

# A Docker tag: alphanumeric/underscore first, then [A-Za-z0-9._-], max 128.
# Deliberately NOT a 40-hex sha pattern -- steam-orchestration's build tags are
# `<orch sha:7>-<analytics sha:7>-<run id>` (steam-infra#119), and the tags
# already in prod from before that are bare shas. Both must pass.
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'

tag_of() { awk '$1=="defaultAirflowTag:"{print $2; exit}' "$1"; }

# Every tag either image file has ever carried, plus whatever they carry now.
# This is the "has this tag actually been deployed" check: a rollback target
# must be something that was in one of these files, not a string someone typed.
# Cheaper and more honest than a registry query -- it proves the tag ran here,
# where GHCR only proves it was built.
known_tags() {
  { git -C "$REPO_ROOT" log -p --no-color --format= -- "$STAGING_REL" "$PROD_REL" 2>/dev/null |
    awk '$1=="+defaultAirflowTag:"{print $2}' || true
  tag_of "$STAGING" 2>/dev/null || true
  tag_of "$PROD" 2>/dev/null || true
  } | sed '/^$/d' | sort -u
}

# Replace the one tag line, leaving every other byte alone. Fails unless
# exactly one line matched, so a renamed key is a loud failure rather than a
# file written without the change the PR title claims.
set_tag() {
  local file="$1" tag="$2" tmp
  tmp=$(mktemp)
  if ! TAG="$tag" awk '
      $1=="defaultAirflowTag:" { print "defaultAirflowTag: " ENVIRON["TAG"]; n++; next }
      { print }
      END { exit (n==1 ? 0 : 1) }' "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

requested=${1:-}

[[ -f "$PROD" ]] || fail "$PROD_REL does not exist -- nothing to promote into."
prod_tag=$(tag_of "$PROD")
[[ -n "$prod_tag" ]] || fail "$PROD_REL has no 'defaultAirflowTag:' value. Fix the file by hand; promotion cannot tell what prod is running."

if [[ -n "$requested" ]]; then
  tag=$requested
  [[ "$tag" =~ $TAG_RE ]] || fail "'$tag' is not a valid image tag."
  # Collected into a variable, not piped into `grep -q`: grep -q exits on the
  # first match and SIGPIPEs the pipeline, which `pipefail` then reports as a
  # failure -- i.e. a known tag would read as unknown.
  known=$(known_tags)
  if ! grep -qxF "$tag" <<<"$known"; then
    fail "$(printf 'tag %s has never been in either image file, so it was never deployed here. Known tags:\n       %s' \
      "$tag" "${known//$'\n'/$'\n'       }")"
  fi
  if git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null | grep -qx true; then
    warn "shallow clone: the known-tag check only saw the history that was fetched. Use fetch-depth: 0."
  fi
  note "promoting an explicitly requested tag (rollback or re-promotion), not staging's current one"
else
  [[ -f "$STAGING" ]] || fail "$STAGING_REL does not exist, so there is no staging tag to promote. Pass a tag explicitly, or check out a revision that has the file."
  tag=$(tag_of "$STAGING")
  [[ -n "$tag" ]] || fail "$STAGING_REL has no 'defaultAirflowTag:' value. Staging's image bot writes that key; a missing one means the bot failed, not that there is nothing to promote."
  [[ "$tag" =~ $TAG_RE ]] || fail "staging's tag '$tag' is not a valid image tag. Promoting it would produce a prod values file that cannot pull an image."
fi

# The no-op. Distinguishing "already promoted" from "the workflow broke" is the
# whole point of failing here instead of letting the PR action produce nothing:
# an empty PR and no PR look identical to whoever clicked Run (steam-infra#119).
if [[ "$tag" == "$prod_tag" ]]; then
  fail "prod already runs $tag, so this promotion would change nothing. No PR was opened and nothing is wrong -- prod and staging are in sync. To redeploy the same tag, sync the prod Application in ArgoCD instead."
fi

set_tag "$PROD" "$tag" || fail "$PROD_REL does not have exactly one 'defaultAirflowTag:' line, so which one prod runs is ambiguous. Fix the file by hand."

ok "$PROD_REL: defaultAirflowTag $prod_tag -> $tag"

# `<orch sha:7>-<analytics sha:7>-<run id>` per steam-infra#119. Older tags are
# bare shas and split into one part; then there is nothing to say and the PR
# body simply omits the line.
detail=""
IFS=- read -r orch analytics run_id extra <<<"$tag" || true
if [[ -n "${run_id:-}" && -z "${extra:-}" ]]; then
  detail="steam-orchestration \`$orch\` · steam-analytics \`$analytics\` · build \`$run_id\`"
fi

{
  echo "promoted_tag=$tag"
  echo "previous_tag=$prod_tag"
  echo "tag_detail=$detail"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
