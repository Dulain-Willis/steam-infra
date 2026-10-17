#!/usr/bin/env bash
# Tests scripts/promote-to-prod.sh against throwaway git repos. Run it:
#
#     bash scripts/promote-to-prod-test.sh
#
# Why this exists: every interesting branch of the promotion is a *refusal* --
# already promoted, a tag that was never deployed, a malformed tag, a missing
# image file -- and none of them can be reached by dispatching the real
# workflow without first breaking the real repo. A live run only ever proves
# the happy path. Same argument, and same shape, as lib/grant_check_test.sh.
#
# Each case builds a tiny repo containing just the two image files and the
# script, runs it, and asserts on exit status, message, and -- for the cases
# that are meant to succeed -- `git diff --numstat`, which is the mechanical
# form of the acceptance criterion "a PR whose only change is prod's image
# tag".
#
# No framework on purpose.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"

SCRIPT="$REPO_ROOT/scripts/promote-to-prod.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0 failed=0
check() { # check "what" "expected" "actual"
  if [[ "$2" == "$3" ]]; then ok "$1"; passed=$((passed + 1))
  else printf '  %s✗ %s%s\n     expected: %s\n     actual:   %s\n' "$RED" "$1" "$RESET" "$2" "$3"; failed=$((failed + 1)); fi
}
check_matches() { # check_matches "what" REGEX "actual"
  if [[ "$3" =~ $2 ]]; then ok "$1"; passed=$((passed + 1))
  else printf '  %s✗ %s%s\n     expected to match: %s\n     actual:   %s\n' "$RED" "$1" "$RESET" "$2" "$3"; failed=$((failed + 1)); fi
}

# image_file ENV TAG -- the real files' shape: a comment block, then two keys.
image_file() {
  printf '# %s image, written by a machine.\n# Second comment line.\ndefaultAirflowRepository: ghcr.io/dulain-willis/steam-orchestration\ndefaultAirflowTag: %s\n' "$1" "$2"
}

# new_repo NAME -- a git repo with both image files at an initial tag, plus a
# third file so "only prod's image file changed" is a real assertion. Prints
# its path. Tags are the real `<orch:7>-<analytics:7>-<run id>` shape.
OLD_TAG=1111111-aaaaaaa-100
NEW_TAG=2222222-bbbbbbb-200
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/k8s/airflow" "$dir/scripts/lib"
  cp "$SCRIPT" "$dir/scripts/promote-to-prod.sh"
  cp "$REPO_ROOT/scripts/lib/output.sh" "$dir/scripts/lib/output.sh"
  image_file staging "$OLD_TAG" >"$dir/k8s/airflow/values-image-staging.yaml"
  image_file prod "$OLD_TAG" >"$dir/k8s/airflow/values-image-prod.yaml"
  echo "unrelated" >"$dir/k8s/airflow/values-prod.yaml"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qam "initial" --allow-empty 2>/dev/null ||
    { git -C "$dir" add -A && git -C "$dir" -c user.email=t@t -c user.name=t commit -qm initial; }
  # Staging moves on, as the image bot would, in its own commit -- so the old
  # tag is only in history, which is what a rollback has to find.
  image_file staging "$NEW_TAG" >"$dir/k8s/airflow/values-image-staging.yaml"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "bump staging"
  echo "$dir"
}

run() { # run DIR [TAG] -- stdout+stderr combined, status in $status
  local dir="$1"; shift
  out=$(cd "$dir" && bash scripts/promote-to-prod.sh "$@" 2>&1)
  status=$?
}

banner "promote-to-prod.sh"

# --- 1. the default case: staging and prod differ ---------------------------
nstep 1 "staging and prod differ: prod is set to staging's tag, and nothing else changes"
dir=$(new_repo differ)
run "$dir"
check "exit 0" 0 "$status"
check "prod's tag is now staging's" "$NEW_TAG" "$(awk '$1=="defaultAirflowTag:"{print $2}' "$dir/k8s/airflow/values-image-prod.yaml")"
check "outputs promoted_tag" "promoted_tag=$NEW_TAG" "$(grep '^promoted_tag=' <<<"$out")"
check "outputs previous_tag" "previous_tag=$OLD_TAG" "$(grep '^previous_tag=' <<<"$out")"
# shellcheck disable=SC2016  # the backticks are literal expected output
check "outputs a legible tag_detail" 'tag_detail=steam-orchestration `2222222` · steam-analytics `bbbbbbb` · build `200`' "$(grep '^tag_detail=' <<<"$out")"
# The acceptance criterion, mechanically: one file, one line added, one removed.
check "the whole diff is one line of one file" "1	1	k8s/airflow/values-image-prod.yaml" "$(git -C "$dir" diff --numstat)"
check "the changed line is only the tag" "+defaultAirflowTag: $NEW_TAG" \
  "$(git -C "$dir" diff -U0 | grep '^+[^+]')"

# --- 2. the no-op ----------------------------------------------------------
nstep 2 "staging and prod already match: refuses, says so, and changes nothing"
dir=$(new_repo noop)
image_file prod "$NEW_TAG" >"$dir/k8s/airflow/values-image-prod.yaml"
git -C "$dir" add -A && git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "prod caught up"
run "$dir"
check "exit 1" 1 "$status"
check_matches "names the tag and says prod is in sync" "prod already runs $NEW_TAG" "$out"
check_matches "says no PR was opened, so 'no PR' is not ambiguous" 'No PR was opened and nothing is wrong' "$out"
check_matches "says why: it is staging's current tag" "staging's current tag, so prod and staging are already in sync" "$out"
check "the tree is untouched" "" "$(git -C "$dir" status --porcelain)"

# The same refusal reached by an explicit tag must NOT claim the environments
# are in sync -- staging may be somewhere else entirely.
run "$dir" "$NEW_TAG"
check "exit 1" 1 "$status"
check_matches "explicit no-op refuses too" "prod already runs $NEW_TAG" "$out"
check "explicit no-op does not claim staging is in sync" "" "$(grep -o 'in sync' <<<"$out")"

# --- 3. rollback: an explicit older tag ------------------------------------
nstep 3 "an explicit older tag: an equivalent rollback, found in history"
dir=$(new_repo rollback)
run "$dir"                                 # promote staging's tag first,
git -C "$dir" add -A                       # and merge it, as the PR would,
git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "promote $NEW_TAG"
run "$dir" "$OLD_TAG"                      # then roll back to the older one
check "exit 0" 0 "$status"
check "prod is back on the old tag" "$OLD_TAG" "$(awk '$1=="defaultAirflowTag:"{print $2}' "$dir/k8s/airflow/values-image-prod.yaml")"
check "outputs previous_tag" "previous_tag=$NEW_TAG" "$(grep '^previous_tag=' <<<"$out")"
check_matches "says it is not staging's current tag" 'explicitly requested tag' "$out"
check "the whole diff is still one line of one file" "1	1	k8s/airflow/values-image-prod.yaml" "$(git -C "$dir" diff --numstat)"

# --- 4. a tag nothing ever deployed ----------------------------------------
nstep 4 "a tag that is in no image file and no history: refuses and lists what is known"
dir=$(new_repo unknown)
run "$dir" "9999999-ccccccc-999"
check "exit 1" 1 "$status"
check_matches "says it was never deployed here" 'never been in either image file' "$out"
check_matches "lists the staging tag it does know" "$NEW_TAG" "$out"
check_matches "lists the historical tag it does know" "$OLD_TAG" "$out"
check "the tree is untouched" "" "$(git -C "$dir" status --porcelain)"

# --- 5. a malformed tag ----------------------------------------------------
nstep 5 "a malformed explicit tag: refused before anything else"
dir=$(new_repo malformed)
run "$dir" "-nope:/v1"
check "exit 1" 1 "$status"
check_matches "says it is not a valid tag" 'not a valid image tag' "$out"
check "the tree is untouched" "" "$(git -C "$dir" status --porcelain)"

# A 40-hex sha and the three-part build tag must BOTH pass the format check:
# prod's pre-#119 tags are bare shas, so a sha-shaped validator would refuse
# every rollback to anything older than #119.
nstep 6 "a bare 40-hex sha is still a promotable tag (prod's pre-#119 tags are)"
dir=$(new_repo baresha)
sha=46d85e2e6baf78611ef01367b8a6e77dcbeb4762
image_file staging "$sha" >"$dir/k8s/airflow/values-image-staging.yaml"
git -C "$dir" add -A && git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "bare sha"
run "$dir"
check "exit 0" 0 "$status"
check "prod took the sha" "$sha" "$(awk '$1=="defaultAirflowTag:"{print $2}' "$dir/k8s/airflow/values-image-prod.yaml")"
check "tag_detail is empty rather than wrong" "tag_detail=" "$(grep '^tag_detail=' <<<"$out")"

# --- 7. staging's tag is empty --------------------------------------------
nstep 7 "staging's defaultAirflowTag is empty: refuses, and blames the bot not the promotion"
dir=$(new_repo emptytag)
image_file staging "" >"$dir/k8s/airflow/values-image-staging.yaml"
run "$dir"
check "exit 1" 1 "$status"
check_matches "names the key and the bot" 'no .defaultAirflowTag:. value' "$out"
check "prod is untouched" "$OLD_TAG" "$(awk '$1=="defaultAirflowTag:"{print $2}' "$dir/k8s/airflow/values-image-prod.yaml")"

# --- 8. staging's image file is missing ------------------------------------
nstep 8 "staging's image file does not exist: refuses and names the file"
dir=$(new_repo nostaging)
rm "$dir/k8s/airflow/values-image-staging.yaml"
run "$dir"
check "exit 1" 1 "$status"
check_matches "names the missing file" 'values-image-staging.yaml does not exist' "$out"
check_matches "says a tag can be passed instead" 'Pass a tag explicitly' "$out"

# --- 9. prod's image file is missing --------------------------------------
nstep 9 "prod's image file does not exist: refuses rather than creating one"
dir=$(new_repo noprod)
rm "$dir/k8s/airflow/values-image-prod.yaml"
run "$dir"
check "exit 1" 1 "$status"
check_matches "names the missing file" 'values-image-prod.yaml does not exist' "$out"
check "did not create it" "absent" "$([[ -f "$dir/k8s/airflow/values-image-prod.yaml" ]] && echo present || echo absent)"

# --- 10. the key was renamed ----------------------------------------------
nstep 10 "prod's file has no tag key: refuses instead of writing a file the PR title lies about"
dir=$(new_repo nokey)
printf 'defaultAirflowRepository: ghcr.io/x\nairflowTag: %s\n' "$OLD_TAG" >"$dir/k8s/airflow/values-image-prod.yaml"
run "$dir"
check "exit 1" 1 "$status"
check_matches "names the key" 'no .defaultAirflowTag:. value' "$out"

# --- 11. two tag lines -----------------------------------------------------
nstep 11 "prod's file has two tag lines: refuses, because which one prod runs is ambiguous"
dir=$(new_repo dupekey)
printf 'defaultAirflowRepository: ghcr.io/x\ndefaultAirflowTag: %s\ndefaultAirflowTag: %s\n' "$OLD_TAG" "$NEW_TAG" >"$dir/k8s/airflow/values-image-prod.yaml"
run "$dir"
check "exit 1" 1 "$status"
check_matches "says it is ambiguous" 'exactly one .defaultAirflowTag:. line' "$out"
check "wrote nothing" "2" "$(grep -c '^defaultAirflowTag:' "$dir/k8s/airflow/values-image-prod.yaml")"

# --- 12. comments and the other key survive the edit ----------------------
nstep 12 "the edit preserves comments, key order and the repository key byte for byte"
dir=$(new_repo preserve)
before=$(grep -v '^defaultAirflowTag:' "$dir/k8s/airflow/values-image-prod.yaml")
run "$dir"
check "exit 0" 0 "$status"
check "every line but the tag is identical" "$before" "$(grep -v '^defaultAirflowTag:' "$dir/k8s/airflow/values-image-prod.yaml")"

printf '\n'
if ((failed)); then
  printf '  %s✗ %s passed, %s failed%s\n' "$RED" "$passed" "$failed" "$RESET"
  exit 1
fi
ok "$passed checks passed"
