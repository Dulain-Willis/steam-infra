#!/usr/bin/env bash
# Bring-up entrypoint: sequences the numbered stages in bringup/stages/.
# Each stage is its own executable script (sources lib/ itself) so it can
# also be run standalone, e.g.:
#   bringup/stages/02-aws.sh
#
# Flags:
#   --start-from N   skip stages before N (resuming after a partial run).
#                     N > 1 skips Stage 1 entirely, which is how "resuming
#                     never destroys what's already up" (#84) holds: Stage
#                     1's leftover-teardown check only runs as part of Stage
#                     1 itself.
#   --stop-after N   stop after stage N (for testing a partial bring-up)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"

START_FROM=1
STOP_AFTER=999

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-from) START_FROM="$2"; shift 2 ;;
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    *) fail "unknown flag: $1" ;;
  esac
done

mapfile -t STAGE_SCRIPTS < <(find "$REPO_ROOT/bringup/stages" -maxdepth 1 -name '*.sh' | sort)

banner "steam-infra bring-up"

for stage_script in "${STAGE_SCRIPTS[@]}"; do
  n=$(basename "$stage_script" | grep -oE '^[0-9]+')
  n=$((10#$n))
  (( n < START_FROM )) && continue
  (( n > STOP_AFTER )) && break
  bash "$stage_script"
done

printf '\n%s%s✓ bring-up complete%s\n\n' "$BOLD" "$GREEN" "$RESET"
