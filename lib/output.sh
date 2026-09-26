#!/usr/bin/env bash
# Terminal output helpers shared by bring-up and teardown. Sourced by stage
# scripts and the two entrypoints — never run directly.
#
# Stages run as separate `bash` processes (so "run one stage on its own"
# works, #85), so stage() takes its position explicitly rather than counting
# a shared in-process counter.

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

banner() { printf '\n%s%s  %s%s\n\n' "$BOLD" "$BLUE" "$1" "$RESET"; }

# stage N TOTAL "Name"
stage() { printf '\n%s%s▸ Stage %s/%s · %s%s\n' "$BOLD" "$BLUE" "$1" "$2" "$3" "$RESET"; }

say()  { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }

# skip "reason" — this stage's target state already holds. Exits 0.
skip() { printf '  %s✓ skip%s — %s\n' "$GREEN" "$RESET" "$1"; exit 0; }

# fail "reason" — unrecoverable for this stage. Exits 1.
fail() { printf '  %s✗ %s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# Numbered sub-steps within a stage: nstep prints "N. label", nsub/nbullet
# indent body lines to sit past the "N. " so nothing lines up under the number.
nstep()   { printf '\n  %s%s.%s %s\n' "$BOLD" "$1" "$RESET" "$2"; }
nsub()    { printf '     %s\n' "$1"; }
nbullet() { printf '     %s•%s %s\n' "$BLUE" "$RESET" "$1"; }

# Logs from run_step live here (predictable path, survives the run).
LOG_DIR="${TMPDIR:-/tmp}/steam-infra"
mkdir -p "$LOG_DIR"

# run_step "label" CMD...  runs CMD with its output hidden. On success: one
# quiet line. On failure: the tail of its log, then exit 1. Keeps tofu/kubectl/
# helm noise off the screen without losing it when something breaks.
run_step() {
  local label="$1"; shift
  local slug log
  slug=$(printf '%s' "$label" | tr -cs 'a-zA-Z0-9' '-')
  log="$LOG_DIR/${slug%-}.log"
  if ! "$@" >"$log" 2>&1; then
    warn "$label failed — tail of $log:"
    tail -n 40 "$log" >&2
    exit 1
  fi
  ok "$label"
}
