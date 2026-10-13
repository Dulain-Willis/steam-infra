#!/usr/bin/env bash
# Bring-up's grant-isolation seam (#114): proves each pipeline identity can
# write exactly where it should and nowhere else, by authenticating as that
# identity with its own tofu-generated key rather than as the operator with
# `--role`. Sourced by scripts/bringup/stages/02-snowflake.sh — never run
# directly. The cases live in that stage, next to the databases they name.
#
# Depends on lib/output.sh (fail/warn/ok/nbullet) and lib/env.sh (sf_query,
# sf_output) already being sourced.
#
# Authenticating as the service users, rather than `sf_query --role LOADER` as
# the operator, needs no extra grant (that would require granting pipeline
# roles to a human) and proves more: that the generated key pair actually
# authenticates, which is the other half of "this identity works".
#
# lib/grant_check_test.sh exercises every branch below with sf_query and
# sf_output stubbed, including the cases a live run cannot reach — a broken
# boundary, and an unreadable key. Run it after changing anything here.

# Objects each probe creates and drops. One name per kind, reused: CREATE OR
# REPLACE means something left behind by an interrupted run can't be mistaken
# for a missing privilege.
#
# Both kinds exist because SELECT on tables and SELECT on views are separate
# grants in Snowflake, and dbt builds both — the stg and int layers are views,
# the marts are tables. A read check that only ever probed a table would pass
# with the views half of a grant missing.
GRANT_PROBE_TABLE="GRANT_CHECK_PROBE"
GRANT_PROBE_VIEW="GRANT_CHECK_PROBE_VIEW"

# _grant_probe_object KIND TARGET — sets _probe_name/_probe_create/_probe_drop
# for a probe object of that kind in that database.schema.
#
# The view selects a constant rather than the probe table: it has to be
# creatable on its own, or the order the two kinds are probed in would matter.
_grant_probe_object() {
  local kind="$1" target="$2"
  case "$kind" in
    TABLE)
      _probe_name="$target.$GRANT_PROBE_TABLE"
      _probe_create="CREATE OR REPLACE TABLE $_probe_name (probe int)"
      ;;
    VIEW)
      _probe_name="$target.$GRANT_PROBE_VIEW"
      _probe_create="CREATE OR REPLACE VIEW $_probe_name AS SELECT 1 AS probe"
      ;;
    *) fail "grant check: unknown probe object kind '$kind' — use TABLE or VIEW" ;;
  esac
  _probe_drop="DROP $kind IF EXISTS $_probe_name"
}

_GRANT_KEY_DIR=""
declare -A _GRANT_USER
declare -A _GRANT_KEY

# grant_check_local_key IDENTITY USER KEY_PATH — register an identity whose
# key is already on disk instead of being a tofu output.
#
# The developer identity (#115) is the one such case: terraform/snowflake
# registers the *operator's existing* public key on the user it creates for
# them, so tofu never holds that private key and there is nothing to output.
# The key comes from .env's SNOWFLAKE_PRIVATE_KEY_PATH instead.
#
# A path that doesn't exist or holds nothing is fatal here, for the same
# reason an empty tofu output is: it would make every `deny` case for this
# identity pass while asserting nothing.
grant_check_local_key() {
  local identity="$1" user="$2" key_path="$3"
  [[ -s "$key_path" ]] \
    || fail "private key for the $identity grant-check identity is missing or empty: $key_path"
  _GRANT_USER[$identity]="$user"
  _GRANT_KEY[$identity]="$key_path"
}

# _grant_check_init IDENTITY... — fetch each identity's service-user name and
# private key once, up front, in the *calling* shell. Identities already
# registered with grant_check_local_key are left alone.
#
# Deliberately not done lazily inside grant_probe: that runs inside a command
# substitution, where `fail` exits only the subshell. The redirect would have
# already created an empty key file, snowflake_query.py would die reading it,
# and a `deny` case would record that as "denied" — a pass asserting nothing.
_grant_check_init() {
  local identity
  _GRANT_KEY_DIR=$(mktemp -d)
  # mktemp -d is mode 0700, so the keys inside need no further protection.
  for identity in "$@"; do
    [[ -n "${_GRANT_KEY[$identity]:-}" ]] && continue
    sf_output "${identity}_private_key" >"$_GRANT_KEY_DIR/$identity.p8" \
      || fail "could not read ${identity}_private_key from terraform/snowflake"
    [[ -s "$_GRANT_KEY_DIR/$identity.p8" ]] \
      || fail "${identity}_private_key from terraform/snowflake is empty"
    _GRANT_KEY[$identity]="$_GRANT_KEY_DIR/$identity.p8"
    _GRANT_USER[$identity]=$(sf_output "${identity}_user") \
      || fail "could not read ${identity}_user from terraform/snowflake"
  done
}

# grant_check_cleanup — safe as an EXIT trap, always returns 0.
grant_check_cleanup() {
  [[ -n "$_GRANT_KEY_DIR" ]] && rm -rf "$_GRANT_KEY_DIR"
  return 0
}

# grant_probe IDENTITY ROLE SQL — run one statement as that identity and role.
# Prints Snowflake's output (stderr folded in) and exits non-zero if the
# statement was refused. That exit code is the whole assertion.
grant_probe() {
  local identity="$1" role="$2" sql="$3"
  SNOWFLAKE_USER="${_GRANT_USER[$identity]}" \
    SNOWFLAKE_PRIVATE_KEY_PATH="${_GRANT_KEY[$identity]}" \
    sf_query "$sql" --role "$role" 2>&1
}

# grant_isolation_check CASE... — each CASE is "IDENTITY ROLE TARGET EXPECT",
# where EXPECT is `allow` (the write must succeed) or `deny` (Snowflake must
# refuse it). See the stage for what the rows mean and the invariant to keep.
grant_isolation_check() {
  local cases=("$@") grant_case identity role target expect output
  local identities=()

  mapfile -t identities < <(printf '%s\n' "${cases[@]}" | awk '{print $1}' | sort -u)
  _grant_check_init "${identities[@]}"

  for grant_case in "${cases[@]}"; do
    read -r identity role target expect <<<"$grant_case"
    # A typo'd or missing expectation would otherwise read as "deny" and pass
    # silently, which is the one failure mode a check like this must not have.
    case "$expect" in
      allow | deny) ;;
      *) fail "grant case '$grant_case' has an unknown expectation '$expect' — use allow or deny" ;;
    esac

    if output=$(grant_probe "$identity" "$role" \
      "CREATE OR REPLACE TABLE $target.$GRANT_PROBE_TABLE (probe int)"); then
      # Drop before deciding, so a boundary violation doesn't also leave the
      # probe table behind: it would be owned by the wrong role, and the next
      # bring-up's CREATE OR REPLACE from the rightful writer would need an
      # OWNERSHIP it hasn't got — failing its *allow* case with a misleading
      # "that write must succeed".
      grant_probe "$identity" "$role" "DROP TABLE IF EXISTS $target.$GRANT_PROBE_TABLE" >/dev/null \
        || fail "$role created $target.$GRANT_PROBE_TABLE but could not drop it again"
      [[ "$expect" == allow ]] \
        || fail "$role wrote $target — that write must be denied; check terraform/snowflake/identities.tf"
      nbullet "$role may write $target"
    else
      if [[ "$expect" == allow ]]; then
        warn "$output"
        fail "$role could not write $target — that write must succeed; check terraform/snowflake/identities.tf, or the service user's key pair if the error above is an authentication failure"
      fi
      nbullet "$role is denied $target"
    fi
  done
  ok "${#cases[@]} grant cases hold"
}

# grant_handoff_check WRITER_IDENTITY WRITER_ROLE READER_IDENTITY READER_ROLE TARGET [KIND...]
#
# The writer creates an object in TARGET and the reader must be able to SELECT
# it. This is the grant the raw/prod split exists for and the one the case
# table above cannot express, since that only probes writes. Worth its own
# step for two reasons:
#
#  - the probe object is created *after* the grants were applied, so this
#    exercises the future-objects grant specifically. An all-only grant matrix
#    passes `tofu validate` and then fails here rather than in Stage 6, after
#    the whole AWS build.
#  - it is the cheapest check that catches a schema which ended up with no
#    grants at all — see the ordering note in terraform/snowflake/identities.tf.
#
# KIND defaults to TABLE. Pass `TABLE VIEW` where the reader must read both:
# CI's read of STEAM_PROD is the case, because slim-CI deferral resolves to
# whichever layer an unselected model lives in and the stg and int layers are
# views. A writer without CREATE VIEW on the target — LOADER on STEAM_RAW —
# must not be asked for one, which is why this is per call site and not the
# default.
grant_handoff_check() {
  local writer="$1" writer_role="$2" reader="$3" reader_role="$4" target="$5"
  local kinds=("${@:6}") kind output
  local _probe_name _probe_create _probe_drop
  ((${#kinds[@]})) || kinds=(TABLE)

  for kind in "${kinds[@]}"; do
    _grant_probe_object "$kind" "$target"
    if ! output=$(grant_probe "$writer" "$writer_role" "$_probe_create"); then
      warn "$output"
      fail "$writer_role could not create $kind $_probe_name — check its grants in terraform/snowflake/identities.tf"
    fi
    if ! output=$(grant_probe "$reader" "$reader_role" "SELECT probe FROM $_probe_name"); then
      warn "$output"
      grant_probe "$writer" "$writer_role" "$_probe_drop" >/dev/null || true
      fail "$reader_role could not read $kind $_probe_name — dbt reads $target through this grant; check the SELECT grant on ${kind}S in terraform/snowflake/identities.tf"
    fi
    grant_probe "$writer" "$writer_role" "$_probe_drop" >/dev/null \
      || fail "could not drop $kind $_probe_name after the handoff check"
  done
  ok "$writer_role writes $target and $reader_role reads it (${kinds[*]})"
}

# grant_read_deny_check WRITER_IDENTITY WRITER_ROLE READER_IDENTITY READER_ROLE TARGET
#
# The mirror of the above: the writer creates a table and the reader must *not*
# be able to SELECT it.
#
# identities.tf makes several claims of the form "this role has no grant of any
# kind on that database" — DEVELOPER on STEAM_PROD, CI on STEAM_STAGING, each
# transformer on the other's database. Nothing else here can see them.
# GRANT_CASES only ever issues CREATE OR REPLACE TABLE, so a stray `SELECT` or
# `USAGE` grant added to one of those databases leaves every write-deny row,
# every handoff check and the whole of grant_check_test.sh passing — and a
# one-token edit in one of identities.tf's near-identical grant blocks is
# exactly how that would happen.
#
# The writer is here for the same reason it is in the handoff check and in
# GRANT_CASES' allow rows: Snowflake answers "you have no USAGE on this
# database" and "this object does not exist" identically, so a read denial over
# an object that is not there asserts nothing. Creating it first is what makes
# the denial mean "refused".
grant_read_deny_check() {
  local writer="$1" writer_role="$2" reader="$3" reader_role="$4" target="$5"
  local table="$target.$GRANT_PROBE_TABLE" output read_output status
  local drop="DROP TABLE IF EXISTS $table"

  if ! output=$(grant_probe "$writer" "$writer_role" "CREATE OR REPLACE TABLE $table (probe int)"); then
    warn "$output"
    fail "$writer_role could not create $table — check its grants in terraform/snowflake/identities.tf"
  fi
  read_output=$(grant_probe "$reader" "$reader_role" "SELECT probe FROM $table")
  status=$?
  grant_probe "$writer" "$writer_role" "$drop" >/dev/null \
    || fail "could not drop $table after the read-deny check"
  if ((status == 0)); then
    warn "$read_output"
    fail "$reader_role read $target — it must have no grant there at all; check terraform/snowflake/identities.tf"
  fi
  ok "$reader_role is denied reads of $target"
}
