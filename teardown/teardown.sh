#!/usr/bin/env bash
# Teardown entrypoint: sequences the numbered stages in teardown/stages/.
# Each stage is its own executable script (source lib/ itself) so it can
# also be run standalone, e.g.:
#   teardown/stages/03-replication-slot.sh
#
# Flags:
#   --start-from N   skip stages before N (resuming after a partial run)
#   --stop-after N   stop after stage N (for testing a partial teardown)
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

mapfile -t STAGE_SCRIPTS < <(find "$REPO_ROOT/teardown/stages" -maxdepth 1 -name '*.sh' | sort)

banner "steam-infra teardown"

for stage_script in "${STAGE_SCRIPTS[@]}"; do
  n=$(basename "$stage_script" | grep -oE '^[0-9]+')
  n=$((10#$n))
  (( n < START_FROM )) && continue
  (( n > STOP_AFTER )) && break
  bash "$stage_script"
done

printf '\n%s%s✓ teardown complete%s\n\n' "$BOLD" "$GREEN" "$RESET"
