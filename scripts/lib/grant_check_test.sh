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

# VIEW as well as TABLE in the keyword alternation: grant_handoff_check probes
# both kinds where the reader has to read both (CI on STEAM_PROD). The stub
# models grants per database.schema and not per object type, so the kinds are
# only plumbing here — "the VIEWS half of a grant is missing" is a scenario the
# live Stage 2 catches and this file cannot, which is the honest division:
# modelling object types would mean a second grant matrix for one scenario.
sf_query() {
  local sql="$1" role="$3" target allowed
  [[ -s "$SNOWFLAKE_PRIVATE_KEY_PATH" ]] || {
    echo "could not deserialize private key"
    return 1
  }
  target=$(sed -E 's/.*(TABLE|VIEW|FROM) (IF EXISTS )?([A-Z_]+\.[A-Z_]+)\..*/\3/' <<<"$sql")
  if [[ "$sql" == SELECT* ]]; then allowed="$READABLE"; else allowed="$WRITABLE"; fi
  [[ " $allowed " == *" $role|$target "* ]] && return 0
  echo "002003 (42S02): SQL compilation error: Object does not exist, or operation cannot be performed."
  return 1
}

# shellcheck source=scripts/lib/grant_check.sh
source "$REPO_ROOT/scripts/lib/grant_check.sh"

RAW="STEAM_RAW.STEAM_RDS"
STAGING="STEAM_STAGING.PUBLIC"
PROD="STEAM_PROD.PUBLIC"
DEV="STEAM_DEV.PUBLIC"
# The same table bring-up's Stage 2 ships, so a row added there without a
# scenario here shows up as a stub that does not model it.
CASES=(
  "loader          LOADER              $RAW     allow"
  "loader          LOADER              $PROD    deny"
  "staging_airflow TRANSFORMER_STAGING $STAGING allow"
  "staging_airflow TRANSFORMER_STAGING $PROD    deny"
  "staging_airflow TRANSFORMER_STAGING $RAW     deny"
  "prod_airflow    TRANSFORMER_PROD    $PROD    allow"
  "prod_airflow    TRANSFORMER_PROD    $STAGING deny"
  "prod_airflow    TRANSFORMER_PROD    $RAW     deny"
  "developer       DEVELOPER           $DEV     allow"
  "developer       DEVELOPER           $STAGING deny"
  "developer       DEVELOPER           $PROD    deny"
  "developer       DEVELOPER           $RAW     deny"
  "ci              CI                  $DEV     allow"
  "ci              CI                  $STAGING deny"
  "ci              CI                  $PROD    deny"
  "ci              CI                  $RAW     deny"
)

# CI|$PROD appears in READABLE and not in WRITABLE, which is the whole of
# #112's Q1: CI is the only role that reads a build database it must not
# write. The stub keeps reads and writes separate precisely so that a correct
# configuration like this one is not called broken.
CORRECT_WRITABLE="LOADER|$RAW TRANSFORMER_STAGING|$STAGING TRANSFORMER_PROD|$PROD DEVELOPER|$DEV CI|$DEV"
CORRECT_READABLE="LOADER|$RAW TRANSFORMER_STAGING|$RAW TRANSFORMER_PROD|$RAW DEVELOPER|$RAW CI|$RAW CI|$PROD"

# Every failure scenario below states what it *changes* about the correct
# matrix instead of respelling it. A respelt matrix also drops every role a
# later ticket adds, so the scenario still goes red — for the wrong reason,
# asserting nothing about the boundary it is named after. #119 found exactly
# that when it added a third build database.
plus() { printf '%s %s' "$1" "${*:2}"; }
minus() {
  local out=" $1 " entry
  for entry in "${@:2}"; do out=${out/ $entry / }; done
  printf '%s' "$out"
}

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
        && grant_handoff_check loader LOADER staging_airflow TRANSFORMER_STAGING "$RAW" \
        && grant_handoff_check loader LOADER prod_airflow TRANSFORMER_PROD "$RAW" \
        && grant_handoff_check loader LOADER developer DEVELOPER "$RAW" \
        && grant_handoff_check loader LOADER ci CI "$RAW" \
        && grant_handoff_check prod_airflow TRANSFORMER_PROD ci CI "$PROD" TABLE VIEW \
        && grant_read_deny_check staging_airflow TRANSFORMER_STAGING ci CI "$STAGING" \
        && grant_read_deny_check prod_airflow TRANSFORMER_PROD developer DEVELOPER "$PROD" \
        && grant_read_deny_check staging_airflow TRANSFORMER_STAGING developer DEVELOPER "$STAGING" \
        && grant_read_deny_check prod_airflow TRANSFORMER_PROD staging_airflow TRANSFORMER_STAGING "$PROD" \
        && grant_read_deny_check staging_airflow TRANSFORMER_STAGING prod_airflow TRANSFORMER_PROD "$STAGING"
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
WRITABLE=$(plus "$CORRECT_WRITABLE" "LOADER|$PROD") \
  run_scenario "LOADER can write STEAM_PROD: must be caught" fail

# 3. The other direction: TRANSFORMER_PROD can write the raw database.
WRITABLE=$(plus "$CORRECT_WRITABLE" "TRANSFORMER_PROD|$RAW") \
  run_scenario "TRANSFORMER_PROD can write STEAM_RAW: must be caught" fail

# 4. A permitted write is denied — a missing grant, not a wrong one.
WRITABLE=$(minus "$CORRECT_WRITABLE" "LOADER|$RAW") \
  run_scenario "LOADER cannot write the landing schema: must be caught" fail

# 5. The landing schema ended up with no read grant. This is exactly the
#    failure the identities.tf schema-ordering edge prevents: every write case
#    still passes, and only the handoff check catches it.
READABLE=$(minus "$CORRECT_READABLE" "TRANSFORMER_PROD|$RAW") \
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
WRITABLE=$(plus "$CORRECT_WRITABLE" "DEVELOPER|$PROD") \
  run_scenario "DEVELOPER can write STEAM_PROD: must be caught" fail

# 9. DEVELOPER can write the landing database. A read grant on STEAM_RAW must
#    not come with a write.
WRITABLE=$(plus "$CORRECT_WRITABLE" "DEVELOPER|$RAW") \
  run_scenario "DEVELOPER can write STEAM_RAW: must be caught" fail

# 10. DEVELOPER cannot write its own database — a dev build would fail, and a
#     check that only probed denials would call that a pass.
WRITABLE=$(minus "$CORRECT_WRITABLE" "DEVELOPER|$DEV") \
  run_scenario "DEVELOPER cannot write STEAM_DEV: must be caught" fail

# 11. DEVELOPER cannot read the landing tables. Every dev build's stg layer
#     reads them, so this is the grant dev work depends on; only the handoff
#     check sees it, exactly as for TRANSFORMER_PROD in scenario 5.
READABLE=$(minus "$CORRECT_READABLE" "DEVELOPER|$RAW") \
  run_scenario "DEVELOPER cannot read the landing schema: must be caught" fail

# 12. TRANSFORMER_STAGING can write STEAM_PROD — #112 story 24, and the one
#     boundary a promotion flow depends on: staging runs merged-but-unreviewed
#     code, so this is the grant that stops a bad merge reaching prod's data.
WRITABLE=$(plus "$CORRECT_WRITABLE" "TRANSFORMER_STAGING|$PROD") \
  run_scenario "TRANSFORMER_STAGING can write STEAM_PROD: must be caught" fail

# 13. And the mirror: prod's role reaching into staging's database. Harmless to
#     prod, but it means the two environments are not actually isolated.
WRITABLE=$(plus "$CORRECT_WRITABLE" "TRANSFORMER_PROD|$STAGING") \
  run_scenario "TRANSFORMER_PROD can write STEAM_STAGING: must be caught" fail

# 14. TRANSFORMER_STAGING cannot write its own database — staging's dbt run
#     would fail, which a deny-only check would call a pass.
WRITABLE=$(minus "$CORRECT_WRITABLE" "TRANSFORMER_STAGING|$STAGING") \
  run_scenario "TRANSFORMER_STAGING cannot write STEAM_STAGING: must be caught" fail

# 15. TRANSFORMER_STAGING cannot read the landing tables — staging's stg layer
#     reads them, and only the handoff check sees this (scenario 5's shape).
READABLE=$(minus "$CORRECT_READABLE" "TRANSFORMER_STAGING|$RAW") \
  run_scenario "TRANSFORMER_STAGING cannot read the landing schema: must be caught" fail

# 16. The operator's key is missing or empty. Unlike the tofu-generated keys,
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

# 17. CI can write STEAM_PROD. CI *reads* prod for slim-CI deferral, so this is
#     the one role where a read grant sits next to a write denial on the same
#     database — the easiest pair to collapse into "just grant it everything"
#     while every other scenario here still passes.
WRITABLE=$(plus "$CORRECT_WRITABLE" "CI|$PROD") \
  run_scenario "CI can write STEAM_PROD: must be caught" fail

# 18. CI can write STEAM_STAGING, which it has no grant of any kind on: a PR's
#     build must not be able to reach the environment merged code runs in.
WRITABLE=$(plus "$CORRECT_WRITABLE" "CI|$STAGING") \
  run_scenario "CI can write STEAM_STAGING: must be caught" fail

# 19. CI can write the landing database. Same shape as DEVELOPER's: the read
#     grant on STEAM_RAW must not arrive with a write.
WRITABLE=$(plus "$CORRECT_WRITABLE" "CI|$RAW") \
  run_scenario "CI can write STEAM_RAW: must be caught" fail

# 20. CI cannot write STEAM_DEV — every CI schema lives there, so a PR's build
#     would fail outright, and a deny-only check would call that a pass.
WRITABLE=$(minus "$CORRECT_WRITABLE" "CI|$DEV") \
  run_scenario "CI cannot write STEAM_DEV: must be caught" fail

# 21. CI cannot *read* STEAM_PROD. Invisible to every write probe above — the
#     deny row on prod passes either way — so only the handoff check sees it.
#     The live symptom is a slim CI build failing with "Object does not exist"
#     on a model the PR never touched, which reads as a dbt bug rather than a
#     missing grant.
READABLE=$(minus "$CORRECT_READABLE" "CI|$PROD") \
  run_scenario "CI cannot read STEAM_PROD: must be caught" fail

# 22. CI cannot read the landing tables. A slim build's stg layer still selects
#     from the sources — only unselected refs defer, and a source is never a
#     ref — so this grant is needed even when nothing upstream is rebuilt.
READABLE=$(minus "$CORRECT_READABLE" "CI|$RAW") \
  run_scenario "CI cannot read the landing schema: must be caught" fail

# 23. CI can *read* STEAM_STAGING. The grant it must not have at all, and the
#     one a write probe cannot see: every GRANT_CASES row still passes, both
#     handoff checks still pass, and a slim CI build would never notice either.
#     A single token in one of identities.tf's near-identical grant blocks —
#     staging's database name where prod's belongs — produces exactly this.
READABLE=$(plus "$CORRECT_READABLE" "CI|$STAGING") \
  run_scenario "CI can read STEAM_STAGING: must be caught" fail

# 24. DEVELOPER can read STEAM_PROD. #112's Q1 turns on DEVELOPER *not* having
#     this while CI does, so the two live next to each other and the mistake is
#     granting the read to both.
READABLE=$(plus "$CORRECT_READABLE" "DEVELOPER|$PROD") \
  run_scenario "DEVELOPER can read STEAM_PROD: must be caught" fail

# 25. And the transformers reading each other's database — "staging and prod
#     are isolated" in the read direction, which until now was asserted only of
#     writes.
READABLE=$(plus "$CORRECT_READABLE" "TRANSFORMER_STAGING|$PROD") \
  run_scenario "TRANSFORMER_STAGING can read STEAM_PROD: must be caught" fail

if ((failures)); then
  printf '\n%d scenario(s) behaved wrongly\n' "$failures" >&2
  exit 1
fi
printf '\nall scenarios behaved correctly\n'
