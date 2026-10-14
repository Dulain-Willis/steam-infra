#!/usr/bin/env bash
# Stage 5: destroy everything except the tfstate bucket. The bucket has
# prevent_destroy = true (so state survives for the next session); a plain
# `tofu destroy` would abort before deleting anything, so those resources
# are excluded instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/teardown_sweep.sh
source "$REPO_ROOT/scripts/lib/teardown_sweep.sh"

stage 5 "tofu destroy"

EXCLUDES=()
for r in "${TFSTATE_RESOURCES[@]}"; do EXCLUDES+=(-exclude="$r"); done

nstep 1 "checking for resources left to destroy..."
remaining=$(tf_leftovers)
if [[ -z "$remaining" ]]; then
  skip "nothing left in state except the tfstate bucket"
fi

# Stage 2 already did this, but it is repeated here because this is the stage
# the leftovers actually break: the alb-controller security groups are not in
# tofu state and DeleteVpc fails with DependencyViolation while they exist
# (#122). Idempotent, bounded the same way, and this is the call that makes
# `teardown.sh --start-from 3` — the resume path #122 was recovered by hand
# with — finish on its own.
nstep 2 "sweeping security groups that would block DeleteVpc..."
sweep_alb_controller_security_groups

nstep 3 "running tofu destroy (excluding the tfstate bucket)..."
run_step "tofu destroy" tf destroy -auto-approve "${EXCLUDES[@]}"

# Only reachable now: a volume attached to a node is `in-use` until that node
# is terminated, which is what the destroy above just did -- but termination
# finishing is not instant either, so one sweep right here can still run
# before a volume has actually detached. That is #124's shape again (a sweep
# that runs once, too early, with nothing re-sweeping after); this stage has
# no escalation path, so re-sweep on every poll instead of claiming clean
# after a single pass. (Stage 6's $0 verify would still catch a leftover
# volume and fail the whole teardown -- better to converge here first.)
nstep 4 "sweeping CSI-provisioned EBS volumes tofu destroy does not own..."
# >&2, not >/dev/null -- see 02-argocd.sh's escalated_cleanup_remaining: warn()
# has no stderr fallback, so a volume that keeps failing delete-volume would
# otherwise lose its diagnostic on every poll instead of just its routine
# "no orphaned CSI volumes" chatter.
sweep_remaining_volumes() { sweep_orphan_volumes >&2; cluster_volumes_count; }
wait_until "$TEARDOWN_ESCALATED_TIMEOUT" sweep_remaining_volumes \
  || fail "EBS volumes are still detaching after ${TEARDOWN_ESCALATED_TIMEOUT}s — MANUAL CHECK REQUIRED, the stack may still be billing"
ok "no orphaned CSI volumes left"

nstep 5 "verifying only the tfstate bucket remains in state..."
remaining=$(tf_leftovers)
if [[ -n "$remaining" ]]; then
  warn "resources still in state:"
  printf '%s\n' "$remaining" >&2
  fail "tofu destroy left resources behind"
fi
ok "tofu state holds only the tfstate bucket"
