#!/usr/bin/env bash
# Tests lib/grant_check.sh against a fake Snowflake. Run it directly:
#
#     bash scripts/lib/grant_check_test.sh
#
# Why this exists: the grant check is the only thing asserting #112's central
# security property, and a live bring-up only ever exercises its happy path —
# correct grants, every case passing. It cannot show that the check *fails*
# when the boundary is actually broken, because that would mean deliberately
# mis-granting the real account. So the cases a live run can't reach are
# covered here with sf_query and sf_output stubbed: a role that can write
# where it must not, a key that won't load, and a landing schema that ended up
# with no grants at all.
#
# No framework on purpose — the repo's only Python convention is PEP-723 + uv,
# and this needs neither.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"

# --- the fake Snowflake -----------------------------------------------------
#
# WRITABLE and READABLE are "ROLE|DATABASE.SCHEMA" pairs the account permits.
# They are separate because the real grant matrix is: TRANSFORMER_PROD reads
# STEAM_RAW but must not write it. A stub that conflated the two would call a
# correct configuration broken.

sf_output() {
  case "$1" in
    *_private_key)
      # EMPTY_KEY_FOR simulates a tofu output that returns nothing.
      [[ "${1%_private_key}" == "${EMPTY_KEY_FOR:-}" ]] && return 0
      echo "KEYMATERIAL-$1"
      ;;
    *_user) echo "SVC_${1%_user}" ;;
    *) return 1 ;;
  esac
}

sf_query() {
  local sql="$1" role="$3" target allowed
  [[ -s "$SNOWFLAKE_PRIVATE_KEY_PATH" ]] || {
    echo "could not deserialize private key"
    return 1
  }
  target=$(sed -E 's/.*(TABLE|FROM) (IF EXISTS )?([A-Z_]+\.[A-Z_]+)\..*/\3/' <<<"$sql")
  if [[ "$sql" == SELECT* ]]; then allowed="$READABLE"; else allowed="$WRITABLE"; fi
  [[ " $allowed " == *" $role|$target "* ]] && return 0
  echo "002003 (42S02): SQL compilation error: Object does not exist, or operation cannot be performed."
  return 1
}

# shellcheck source=scripts/lib/grant_check.sh
source "$REPO_ROOT/scripts/lib/grant_check.sh"

RAW="STEAM_RAW.STEAM_RDS"
PROD="STEAM_PROD.PUBLIC"
DEV="STEAM_DEV.PUBLIC"
CASES=(
  "loader       LOADER           $RAW  allow"
  "loader       LOADER           $PROD deny"
  "prod_airflow TRANSFORMER_PROD $PROD allow"
  "prod_airflow TRANSFORMER_PROD $RAW  deny"
  "developer    DEVELOPER        $DEV  allow"
  "developer    DEVELOPER        $PROD deny"
  "developer    DEVELOPER        $RAW  deny"
)

CORRECT_WRITABLE="LOADER|$RAW TRANSFORMER_PROD|$PROD DEVELOPER|$DEV"
CORRECT_READABLE="LOADER|$RAW TRANSFORMER_PROD|$RAW DEVELOPER|$RAW"

# The developer identity's key is the operator's own, already on disk, rather
# than a tofu-generated one — the module registers the operator's existing
# public key on the user it creates, so there is no private key to output.
# grant_check_local_key is that seam; this file is where it gets exercised.
DEV_KEY_FILE="$(mktemp)"
printf 'KEYMATERIAL-operator\n' >"$DEV_KEY_FILE"
EMPTY_KEY_FILE="$(mktemp)"
trap 'rm -f "$DEV_KEY_FILE" "$EMPTY_KEY_FILE"' EXIT

# run_scenario "name" pass|fail [CASE...] -- runs the check in a subshell with
# WRITABLE/READABLE/EMPTY_KEY_FOR taken from the environment, and asserts the
# overall outcome. Prints the check's own output only when it misbehaves.
#
# Cases come as trailing arguments, defaulting to $CASES: an array cannot be
# set in a command prefix (`CASES=(...) run_scenario` assigns the *string*
# "(...)"), which is a quiet way to write a test that passes for the wrong
# reason.
failures=0
run_scenario() {
  local name="$1" expect="$2" out status
  local cases=("${@:3}")
  ((${#cases[@]})) || cases=("${CASES[@]}")
  # A subshell, because `fail` exits: that is what the status under test is.
  # stderr is folded in and only shown when the outcome is wrong, so an
  # expected failure doesn't look like a real one in the log.
  out=$(
    {
      set -uo pipefail
      WRITABLE="${WRITABLE:-$CORRECT_WRITABLE}"
      READABLE="${READABLE:-$CORRECT_READABLE}"
      EMPTY_KEY_FOR="${EMPTY_KEY_FOR:-}"
      export WRITABLE READABLE EMPTY_KEY_FOR
      grant_check_local_key developer SVC_developer "${DEV_KEY:-$DEV_KEY_FILE}" \
        && grant_isolation_check "${cases[@]}" \
        && grant_handoff_check loader LOADER prod_airflow TRANSFORMER_PROD "$RAW" \
        && grant_handoff_check loader LOADER developer DEVELOPER "$RAW"
      grant_check_cleanup
    } 2>&1
  )
  status=$?
  if [[ "$expect" == pass && $status -ne 0 ]]; then
    printf 'FAIL  %s — expected the check to pass, it failed:\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  elif [[ "$expect" == fail && $status -eq 0 ]]; then
    printf 'FAIL  %s — expected the check to FAIL, it passed (false green):\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  else
    printf 'ok    %s\n' "$name"
  fi
}

# 1. The configuration this ticket ships.
run_scenario "correct grants: all cases and the handoff hold" pass

# 2. The boundary is broken: LOADER can also write STEAM_PROD. This is the
#    scenario a live run cannot produce, and the whole reason for the check.
WRITABLE="LOADER|$RAW LOADER|$PROD TRANSFORMER_PROD|$PROD" \
  run_scenario "LOADER can write STEAM_PROD: must be caught" fail

# 3. The other direction: TRANSFORMER_PROD can write the raw database.
WRITABLE="LOADER|$RAW TRANSFORMER_PROD|$PROD TRANSFORMER_PROD|$RAW" \
  run_scenario "TRANSFORMER_PROD can write STEAM_RAW: must be caught" fail

# 4. A permitted write is denied — a missing grant, not a wrong one.
WRITABLE="TRANSFORMER_PROD|$PROD" \
  run_scenario "LOADER cannot write the landing schema: must be caught" fail

# 5. The landing schema ended up with no read grant. This is exactly the
#    failure the identities.tf schema-ordering edge prevents: every write case
#    still passes, and only the handoff check catches it.
READABLE="LOADER|$RAW" \
  run_scenario "TRANSFORMER_PROD cannot read the landing schema: must be caught" fail

# 6. A key that won't load must not read as "denied". Before the fetch was
#    hoisted out of grant_probe, an identity reached only by deny cases would
#    have passed here while asserting nothing.
EMPTY_KEY_FOR=prod_airflow \
  run_scenario "empty private key: must be caught, not read as a denial" fail

# 7. A malformed case must not be treated as a denial.
run_scenario "typo'd expectation: must be caught" fail "loader LOADER $PROD allowed"

# 8. DEVELOPER can write prod — the boundary #115 exists to enforce, and the
#    one a dev build must be physically unable to cross.
WRITABLE="LOADER|$RAW TRANSFORMER_PROD|$PROD DEVELOPER|$DEV DEVELOPER|$PROD" \
  run_scenario "DEVELOPER can write STEAM_PROD: must be caught" fail

# 9. DEVELOPER can write the landing database. A read grant on STEAM_RAW must
#    not come with a write.
WRITABLE="LOADER|$RAW TRANSFORMER_PROD|$PROD DEVELOPER|$DEV DEVELOPER|$RAW" \
  run_scenario "DEVELOPER can write STEAM_RAW: must be caught" fail

# 10. DEVELOPER cannot write its own database — a dev build would fail, and a
#     check that only probed denials would call that a pass.
WRITABLE="LOADER|$RAW TRANSFORMER_PROD|$PROD" \
  run_scenario "DEVELOPER cannot write STEAM_DEV: must be caught" fail

# 11. DEVELOPER cannot read the landing tables. Every dev build's stg layer
#     reads them, so this is the grant dev work depends on; only the handoff
#     check sees it, exactly as for TRANSFORMER_PROD in scenario 5.
READABLE="LOADER|$RAW TRANSFORMER_PROD|$RAW" \
  run_scenario "DEVELOPER cannot read the landing schema: must be caught" fail

# 12. The operator's key is missing or empty. Unlike the tofu-generated keys,
#     this one is a path from .env, so a wrong path or a key that was never
#     created has to be caught at registration — an identity reached only by
#     `deny` cases would otherwise record "could not authenticate" as
#     "denied" and pass while asserting nothing. Asserted on
#     grant_check_local_key directly, because a scenario would also fail for
#     the uninteresting reason that the allow case could not run.
check_registration_fails() {
  local name="$1" path="$2" out status
  out=$( ( grant_check_local_key developer SVC_developer "$path" ) 2>&1 )
  status=$?
  if ((status == 0)); then
    printf 'FAIL  %s — grant_check_local_key accepted it:\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  else
    printf 'ok    %s\n' "$name"
  fi
}
check_registration_fails "empty local key file: must be rejected" "$EMPTY_KEY_FILE"
check_registration_fails "missing local key file: must be rejected" "/nonexistent/operator.p8"

if ((failures)); then
  printf '\n%d scenario(s) behaved wrongly\n' "$failures" >&2
  exit 1
fi
printf '\nall scenarios behaved correctly\n'
