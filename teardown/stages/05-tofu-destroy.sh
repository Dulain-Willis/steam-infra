#!/usr/bin/env bash
# Stage 5/6: destroy everything except the tfstate bucket. The bucket has
# prevent_destroy = true (so state survives for the next session); a plain
# `tofu destroy` would abort before deleting anything, so those resources
# are excluded instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 5 6 "tofu destroy"

EXCLUDES=()
for r in "${TFSTATE_RESOURCES[@]}"; do EXCLUDES+=(-exclude="$r"); done

nstep 1 "checking for resources left to destroy..."
remaining=$(tf_leftovers)
if [[ -z "$remaining" ]]; then
  skip "nothing left in state except the tfstate bucket"
fi

nstep 2 "running tofu destroy (excluding the tfstate bucket)..."
run_step "tofu destroy" tf destroy -auto-approve "${EXCLUDES[@]}"

nstep 3 "verifying only the tfstate bucket remains in state..."
remaining=$(tf_leftovers)
if [[ -n "$remaining" ]]; then
  warn "resources still in state:"
  printf '%s\n' "$remaining" >&2
  fail "tofu destroy left resources behind"
fi
ok "tofu state holds only the tfstate bucket"
