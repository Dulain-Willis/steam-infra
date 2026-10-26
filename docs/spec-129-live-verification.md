# Spec #129 — live verification results

Bring-up #1 started 2026-10-25, integration branches `spec-129-dirty-data`
(infra `ad2bfbc`, analytics `e09ae23`). Watchdog armed throughout.
Stage 1 reported "no leftovers — starting from nothing", so this is a genuine
from-scratch database and the schema-guard-gated changes are really being tested.

## Step 2 — static schema checks on a fresh database

**#142 / #143 — new `users` columns land on a clean bring-up: PASS**

```
 check      |      column_name      | is_nullable |        data_type
------------+-----------------------+-------------+--------------------------
 users_cols | deletion_executed_at  | YES         | timestamp with time zone
 users_cols | deletion_requested_at | YES         | timestamp with time zone
```

Both nullable, both `timestamptz`. `deletion_executed_at` came from the
integration code review (finding 9) and only ever lands here, since
`schema_guard.py` applies the schema only when absent.

Discharges: #142 "user row carries a deletion-request timestamp, nullable,
defaulting to unset"; #142 "confirmed on a clean bring-up that the schema change
lands".

**#140 — client-event-to-user foreign key dropped, column still non-nullable: PASS**

```
          conname           |                    def
----------------------------+--------------------------------------------
 client_events_game_id_fkey | FOREIGN KEY (game_id) REFERENCES games(id)

 column_name | is_nullable
-------------+-------------
 user_id     | NO
```

The `user_id` foreign key is absent while the `game_id` foreign key survives —
the drop was targeted, not collateral. `user_id` remains `NOT NULL` as the
ticket requires.

Discharges: #140 "confirmed on a clean bring-up that the schema change lands";
#140 "the column stays non-nullable".

## Step 3 — #131 reference scenario against the live database: PASS

`scripts/scenarios/run.sh noop_report` opened the SSM tunnel through the bastion
and ran the cursor-taking `run(cur)` against RDS:

```
game_prices: 15000 | games: 3000 | users: 50000 | marketing_campaigns: 40
client_events: 0 | concurrent_player_snapshots: 0 | family_shares: 0
gifts: 0 | key_redemptions: 0 | ownership_grants: 0 | playtime_sessions: 0
price_changes: 0 | purchases: 0 | refunds: 0 | reviews: 0 | wishlist_items: 0
```

Discharges: #131 "a no-op reference scenario connects to the live database and
reports row counts per table" — the last unchecked criterion on that ticket.

Doubles as the `T0` snapshot for the baseline window: seed tables populated,
every generator-written event table still at zero because Stage 6 had not yet
started the generator. Any non-zero count in those tables later is therefore
attributable to the generator, not to seeding.

## Bring-up complete — full CDC path verified

All 7 stages green. Generator ticking at default rates. `T0` = 2026-10-25 21:04 UTC.

Landing tables in `STEAM_RAW.STEAM_RDS` (read as the `loader` service identity
with its tofu-generated key — the pattern `scripts/lib/grant_check.sh` uses
deliberately, so that no pipeline role is ever granted to a human):

```
client_events 36 | purchases 35 | ownership_grants 50 | users 50000
```

Postgres -> Debezium -> Kafka -> Snowflake sink -> landing tables all confirmed
working on this bring-up.

**CORRECTION — an early observation of mine was wrong.** I initially read "15
purchases against 14 ownership grants" as #133's business-key duplicate fault
appearing on its own at the default rate. That reading was incorrect: #133 was
not merged into the integration branch at that point (see the audit below), so
there was no purchase duplication in the running generator at all. The gap was
ordinary insert-ordering lag between the two tables — the grant is written a
moment after its purchase. No conclusion rests on it.

### Note on reading Snowflake during verification

The operator identity (`DULAIN`, ACCOUNTADMIN) cannot `select` from the
LOADER-owned landing tables, and `--role LOADER` is refused because pipeline
roles are deliberately not granted to humans. `scripts/lib/grant_check.sh`
documents this as a design decision. Verification therefore authenticates as the
service user with its own key rather than granting a pipeline role to the
operator or widening ACCOUNTADMIN's grants — which would have weakened exactly
the isolation #114 asserts.

## Step — #132 part 1: what a delete-derived row actually contains

Deleted `wishlist_items` row `f02836b3-ef94-47f6-900a-45d3e2c2fa3d` in Postgres
(`DELETE 1`, 0 remaining). It arrived in the landing table within seconds:

```
 off | __deleted | uid_null | uid_empty | rec_null | recorded_at
-----+-----------+----------+-----------+----------+-------------------------
   0 | false     | False    | False     | False    | 2026-10-25 21:03:57.193
   5 | false     | False    | False     | False    | 2026-10-25 21:03:57.193
  10 | true      | False    | True      | False    | 1970-01-01 00:00:00.000
```

**PASS** — the delete-derived row is present, carries the deleted flag and the
primary key. Discharges #132 "a row is deleted in the source database and the
delete-derived row is confirmed present in the corresponding landing table,
carrying the deleted flag and the primary key".

### FINDING — delete rows carry sentinel defaults, NOT nulls

This corrects the premise of integration code-review findings 2/3/4/6, which all
stated that every non-key column on a delete row "is NULL". Observed live:

- `recorded_at` is **epoch `1970-01-01 00:00:00`**, and `recorded_at is null` is
  **False**.
- `user_id` is the **empty string**, and `user_id is null` is **False**
  (`user_id = ''` is True).

Every *conclusion* in those findings still holds, because the sentinel sorts at
the bottom of its type's range: `recorded_at >= window` evaluates FALSE rather
than NULL, so the row was still excluded from every incremental fact; and `''`
still hashes to a surrogate key with no dimension row.

**But the mechanism matters, and one proposed fix would have silently failed.**
The code review offered `coalesce(recorded_at, <sentinel>)` as a candidate fix
for finding 2. Against epoch-not-null data, `coalesce` is a no-op and the delete
row would have stayed excluded, with the bug appearing fixed. The fix that
actually shipped — `is_deleted or recorded_at >= window` in
`macros/incremental_lookback_filter.sql` — is correct under both semantics.

Checked for other code depending on the NULL assumption:
- `macros/incremental_lookback_filter.sql` — safe, keys off `is_deleted`.
- `stg_steam__client_events.sql`'s tombstone backfill — safe, and robust by
  accident of a good choice: `max(col) over (partition by event_id)` beats both
  NULL (ignored by `max`) and the sentinel (sorts lowest), so the real pre-delete
  value wins either way.
- No `coalesce(recorded_at…)` or `… is null` delete-path logic exists anywhere in
  `models/`, `macros/` or `tests/`.

Action taken: the explanatory comments that assert "is null" are factually wrong
and are the most likely way a future change reintroduces this bug. Corrected
(see commit below).

### FINDING — a documented connector guarantee is defeated by the sink

`docs/debezium-postgres-config.md:37` documents
`transforms.unwrap.replace.null.with.default=false` with this rationale: "leave a
column genuinely null when the source column is null, rather than substituting
the connector's type default (e.g. `0` for a numeric column), which would be
indistinguishable from a real zero downstream."

The deployed connector really is configured that way (verified against the live
`kafkaconnector/debezium-postgres-source`, not just the manifest). But the
Snowflake sink runs `snowflake.enable.schematization = true` with
`value.converter.schemas.enable = true`, and the schematizing sink materializes
the Connect schema's type defaults for the absent fields. So the type
substitution the connector setting exists to prevent happens one hop downstream
anyway.

The risk the doc names is therefore realised, not avoided: a delete row's
`recorded_at` of `1970-01-01` is indistinguishable from a genuine 1970 timestamp
by inspection of that column alone. It is safe in practice only because
`is_deleted` disambiguates and no real row carries those values. The stated
guarantee is nonetheless false as written.

## Step — #132 part 2: connector restart

Restart issued with `kubectl annotate kafkaconnector debezium-postgres-source
-n kafka strimzi.io/restart=true`. Confirmed a real restart occurred rather than
assumed from the annotation clearing — Kafka Connect logged:

```
"POST /connectors/debezium-postgres-source/restart?includeTasks=false&onlyFailed=false HTTP/1.1" 204
```

Landing table re-inspected for the deleted id afterwards:

```
 off | __deleted | recorded_at
-----+-----------+-------------------------
   0 | false     | 2026-10-25 21:03:57.193
   5 | false     | 2026-10-25 21:03:57.193
  10 | true      | 1970-01-01 00:00:00.000
```

**PASS on all three restart criteria.**

- Still exactly three rows for that id — **no re-snapshot insert appeared after
  the restart**, confirming `snapshot.mode: initial` resumes from the stored
  offset rather than re-reading the table. This is the behaviour #132 predicted
  on paper and the reason the stale `snapshot.mode=always` claim was wrong.
- The highest offset is still the delete row, so under the staging layer's
  `qualify row_number() over (partition by id order by offset desc) = 1` the
  **delete still wins**. The deleted row's last-known state survives the restart.

Discharges: #132 "the source connector is restarted and the landing table
re-inspected; the resulting behaviour is recorded"; #132 "confirmed whether the
deleted row's last-known state survives the restart, i.e. whether the delete
still wins under offset dedupe".

### The offset dedupe is NOT redundant — now confirmed live, not argued

Offsets 0 and 5 are two rows with **identical content** for the same primary key,
present before any restart. That is a real duplicate the dedupe collapses. #132's
written finding reasoned this out from the connector's design; this is the
observed instance. Had the dedupe been removed on the strength of "we don't
re-snapshot on restart", these duplicates would have reached the marts.

This is also why the ticket's scope limit — do not remove or weaken the staging
offset dedupe on the strength of the investigation — was the right call.

**#132 is now fully discharged (all 6 criteria).**

## Step — first live dbt build: two real defects, one of them invisible offline

`dbt run` as the `STEAM_STAGING_SVC` / `TRANSFORMER_STAGING` service identity
against `STEAM_STAGING` (again authenticating as the service user with its
tofu-generated key rather than granting a pipeline role to a human).

First attempt: `Done. PASS=64 WARN=0 ERROR=4 SKIP=8`.

### FINDING — `is_deleted` was a STRING, not a boolean, project-wide

Three facts failed their enforced contract identically:

```
| column_name | definition_type | contract_type | mismatch_reason    |
| IS_DELETED  | TEXT            | BOOLEAN       | data type mismatch |
```

Root cause: the Snowflake sink schematizes Debezium's `__deleted` as `TEXT`
(confirmed in `steam_raw.information_schema.columns`: `__DELETED  TEXT`). So
`coalesce(__deleted, false)` — the derivation used by all 16 staging models, and
pre-existing, not introduced by this spec — returns TEXT. `is_deleted` has been
the *string* `'true'`/`'false'` throughout, and every downstream
`where not is_deleted` has been relying on Snowflake's implicit
string-to-boolean coercion to work at all.

**This is the kind of defect only a live build finds.** `dbt parse` does not
validate contract data types, and #144's author verified that empirically and
deferred the criterion to this phase rather than claiming it offline. The
contracts added by #144 are what surfaced a latent unsoundness that predates the
spec.

Fixed at the root — `coalesce(try_to_boolean(__deleted), false)` across all 16
staging models — rather than relaxing the contracts to `varchar`, which would
have silenced the symptom and left the coercion load-bearing. `try_to_boolean`
rather than `::boolean` so an unexpected value yields null and is caught by the
existing `coalesce` instead of failing the build.

### Harness issue, not a code defect

`int_purchases_with_fx` failed with `Schema 'STEAM_STAGING.STAGING' does not
exist` — the base schema is created by the `fx_rates` seed, and I had run `run`
without `seed`. Running `dbt seed` first (`INSERT 7310`) resolved it. Recorded
so it is not mistaken for a model bug.

### Result after the fix

```
Done. PASS=76 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=76
```

All 76 models build clean on a full refresh, including the five incremental
facts from #134/#135 and every contract-enforced published mart.

Discharges: #144 "published mart models declare their output columns and types"
now proven live rather than by inspection — the contracts are genuinely enforced
and did real work, catching the `is_deleted` mismatch.

## Step — live test suite: my own planning error, plus a real integration bug

`dbt test` first attempt: `Done. PASS=219 WARN=1 ERROR=49`.

### My planning error — minute buckets are not available

46 of the 49 errors were one mistake of mine:

```
time_bucket.period value should be one of ['hour', 'day', 'week', 'month'], got: minute
```

The baseline-compression decision I added to `LIVE-RUNBOOK.md` — overriding
elementary's `time_bucket` to 5-minute buckets to turn a 7-14 hour baseline into
~90 minutes — is simply not possible: elementary validates the period against
`['hour','day','week','month']` and rejects `minute`. The runbook has been
corrected rather than left carrying a plan that cannot work. The baseline
genuinely needs hours of wall-clock history; see the revised plan below.

### Real integration bug — funnel unit tests could not compile

```
Unit_Test '...fct_product_funnel_sessions.test_..._carries_is_deleted_through'
depends on a node named 'dim_users' which was not found
```

#141 made `fct_product_funnel_sessions` left-join `dim_users` so orphan events
resolve to the unknown-member sentinel. Three unit tests for that model predate
the join and declare no `dim_users` input, so they fail to compile. **`dbt parse`
does not catch this** — only `dbt test` compiles unit tests — so it passed every
offline check in every ticket and in both code-review clusters, and only appeared
here. Fixed by giving each the `user_id`-only fixture the model actually reads.

After the fix: `fct_product_funnel_sessions` selector gives
`PASS=20 WARN=1 ERROR=0`.

### #140 and #141 both confirmed live, at DEFAULT rates

That one warning is the point:

```
10 of 18 WARN 1 relationships_fct_product_funnel_sessions_user_id__user_id__ref_dim_users_
[WARNING]: Got 1 result, configured to warn if != 0
```

- #140's orphan injection is real: one orphan client event exists at the default
  orphan rates, with no cranking.
- #141's relationships test reports it at **warn** severity — the build stays
  green while the drift is surfaced, which is exactly the behaviour the ticket
  specifies ("a steady trickle is normal and only a spike is a break").

Discharges: #141 "a relationships test at warning severity reports orphan volume
without failing the build".

## FINDING — the whole warehouse was on America/Los_Angeles, and durations were wrong

Two singular tests failed on real data, not fixtures:

```
assert_fct_product_session_length_daily_non_negative  Got 174 results
assert_fct_wishlist_items_removed_after_added         Got  42 results
```

Traced to one root cause, and it is not in the generator. The source database
has **zero** inverted rows:

```
 inverted | min_min | max_min
----------+---------+---------
        0 |         |
```

The skew is created entirely in the warehouse. A session running
`21:44 -> 21:59` — plainly +15 minutes — measured as **-405**. That is
`15 - 420`, and 420 minutes is the UTC offset of the Snowflake account's
default timezone, `America/Los_Angeles`.

Mechanism, confirmed column by column:

- Postgres stores `timestamptz`; `db/schema.sql:2` states the convention as
  "timestamps: timestamptz UTC"; Debezium emits UTC.
- The sink lands those as `TIMESTAMP_NTZ` holding the UTC wall clock. A
  `::timestamp_tz` cast in staging therefore attaches the **session** timezone,
  not UTC.
- But a nullable timestamp whose first observed value is null cannot be typed by
  the schematizing sink, so it is created as **TEXT** — and its values arrive as
  ISO-8601 with `Z`, which parse as genuine UTC.
- So one side of every such comparison was UTC and the other was UTC-7.

Seven columns across seven tables are TEXT for this reason:

```
FAMILY_SHARES.ENDED_AT        GIFTS.REDEEMED_AT
OWNERSHIP_GRANTS.REVOKED_AT   PLAYTIME_SESSIONS.ENDED_AT
USERS.DELETION_EXECUTED_AT    USERS.DELETION_REQUESTED_AT
WISHLIST_ITEMS.REMOVED_AT
```

The last two are #142's and #143's own columns, so the erasure grace-period
comparison was skewed warehouse-side as well — a latent bug in the erasure work
that no amount of offline testing would have shown, because it requires the real
sink's type inference.

**Fixed** by setting the account `TIMEZONE` to `UTC`, codified as
`snowflake_account_parameter.timezone` in `terraform/snowflake/databases.tf`
(applied, state updated) rather than left as a session setting, so a fresh
bring-up and every identity agree. Both tests pass after rebuilding the affected
models.

This is the single most consequential defect found in the whole spec, and it was
pre-existing infrastructure behaviour that only became visible because #129
added models that compute differences between timestamps.

## Step — #142 + #143: the full erasure drill, both phases

Target `cheryl89_25305` (`3d70f16f-b5cb-4c27-aa94-975ab3103d50`), chosen for
having rows in both tier 1 and tier 3.

### Phase 1 — request, and the grace gate refusing

`scripts/scenarios/run.sh deletion_request` recorded the request. Running the
execution scenario immediately, at the real default grace period, refused:

```
ValueError: cheryl89_25305's grace period (2592000s) has not elapsed yet
(2591994s remaining) -- refusing to erase
```

2592000s is 30 days — the real-world default — and the 6s already elapsed shows
the gate measuring against the database's own clock, not a wall-clock sleep.

### Phase 2 — execution with the grace period overridden to 1s

```
cheryl89_25305: erased (30s into a 1s grace period) -- hard deleted
{'client_events': 1, 'playtime_sessions': 0, 'wishlist_items': 0},
anonymized user row to deleted-user-3d70f16f-b5cb-4c27-aa94-975ab3103d50
```

Before and after in the source database, per tier:

| tier | columns | before | after |
|------|---------|--------|-------|
| 1 hard delete | client_events / playtime_sessions / wishlist_items | 1 / 0 / 0 | **0 / 0 / 0** |
| 2 anonymize | username / email / country | `cheryl89_25305` / `portermelissa25305@hotmail.com` / `BR` | **`deleted-user-3d70f16f…` / `deleted-3d70f16f…@erased.invalid` / blank** |
| 3 retain | purchases / refunds / ownership_grants | 1 / 1 / 1 | **1 / 1 / 1** |

The user row is retained under the same id, with `deletion_executed_at` set.

### The soft-delete-then-hard-delete sequence, as two distinct pipeline events

The landing table holds three CDC versions of the user row, in offset order:

```
 off   | username                      | __deleted | requested_at | executed_at
-------+-------------------------------+-----------+--------------+-------------
 25306 | cheryl89_25305                | false     |              |
 50009 | cheryl89_25305                | false     | 22:12:15     |
 50010 | deleted-user-3d70f16f-b5cb... | false     | 22:12:15     | 22:12:45
```

`__deleted` is false throughout — the user row is correctly never deleted, only
anonymized — while `client_events` received exactly one tombstone. That is the
request and the execution arriving as two separate events, which is spec user
story 28.

### Propagation into the marts

```
 LIVE_EVENTS | TOMBSTONED_EVENTS | PURCHASES_KEPT
-------------+-------------------+----------------
           0 |                 1 |              1
```

- tier 1: the erased user's behavioural rows are **absent** from the warehouse.
- the tombstone is present and carries `is_deleted` — so the macro fix and the
  staging backfill from the integration review both work on real CDC data.
- tier 3: the purchase survives and still joins to the anonymized `dim_users`
  row, which shows `deleted-user-3d70f16f…` with country blanked.

Discharges on #143: grace gate (both directions), behavioural hard delete,
anonymize-in-place with an identifiable tombstone, transaction rows untouched
and still attributable, delete-derived rows in the landing tables, propagation
through staging into the marts, and the two-phase live run with before/after
counts per tier.

Discharges on #142: the request visible as an ordinary update flowing through to
the landing table and the staging layer.

### Note — `on_schema_change: fail` did its job

The first incremental run after the `is_deleted` TEXT->BOOLEAN fix failed with
"the source and target schemas on this incremental model are out of sync". That
is #144's `on_schema_change='fail'` behaving exactly as intended against a real
schema change, not a defect; a full refresh reconciled it.

## Step — #142: a pending request is treated as a normal active user

Second user `christianhaynes_132` (`db3724ef-759f-46f6-bdc6-4c6e7c9e4fde`),
request recorded but NOT executed:

```
 STG_HAS_REQUEST | IN_DIM | STILL_NAMED | LIVE_EVENTS
-----------------+--------+-------------+-------------
               1 |      1 |           1 |           2
```

- the staging layer exposes `deletion_requested_at` — direct proof that the
  one-line passthrough added in commit `b298388` was both necessary and
  sufficient. This is the criterion `LIVE-RUNBOOK.md` had inherited as
  "unverifiable"; it verifies.
- `dim_users` still holds the user under their **real** username, so a pending
  request is an ordinary active user to every consumer.
- their two behavioural rows are untouched: nothing is deleted at request stage.

Discharges: #142 "marts treat a pending request as a normal active user, since
nothing is deleted yet".

## Step — #143 on the INCREMENTAL path, which is the one that matters

The earlier drill was confirmed after a full refresh, and a full refresh has no
lookback filter — so it could not prove the fix. Erasing the second user and
then running **incremental only** (`dbt run --select stg_steam__client_events
fct_product_funnel_sessions`, no `--full-refresh`):

```
 LIVE_EVENTS_AFTER | LIVE_FUNNEL_AFTER | DELETED_FUNNEL_AFTER
-------------------+-------------------+----------------------
                 0 |                 0 |                    1
```

Every link in the chain the integration review repaired is exercised here:

1. the tombstone passed `incremental_lookback_filter()` via its `is_deleted`
   branch, despite an epoch `recorded_at` far outside the window (finding 2);
2. `stg_steam__client_events` backfilled the tombstone's `session_id` from its
   own pre-delete row, so it could still be attributed to a session (finding 6);
3. `touched_sessions` therefore revisited the session, and the merge flipped the
   **already-materialised** row to `is_deleted = true`.

Without those fixes this would read `LIVE_FUNNEL_AFTER = 1` and
`DELETED_FUNNEL_AFTER = 0`, permanently — the erased user's funnel session
sitting in the mart forever, with the pipeline reporting success. That was a real
compliance hole in the merged spec, and this is it closed and measured.

**#143's headline criterion — "the derived delete flag propagates through
staging into the marts; erased behavioural rows are absent from marts after the
next run" — is discharged on the incremental path.**

## Step — #144: additive migration against a live connector, and contract enforcement

### The migration

`scripts/scenarios/run.sh games_add_column` ran
`alter table games add column if not exists early_access boolean;` against the
live source database. Confirmed in Postgres as `early_access | boolean | YES`.

A column only reaches the landing table once a row change carries the new
schema, so one `games` row was updated (`early_access = true`). The sink then
absorbed the column on its own:

```
attempt 1..5: EARLY_ACCESS present in landing = 0
attempt 6:    EARLY_ACCESS present in landing = 1
```

**No connector reconfiguration, no restart, no intervention.** `dbt build
--select stg_steam__games+` then completed `PASS=26 ERROR=0`.

The staging model's explicit select list means `early_access` does not silently
propagate into a published mart — which is the designed behaviour, not a gap:
the point of the contracts is that a published shape changes only deliberately.

Discharges: #144 "a scenario adds a new nullable column to the source table";
"the new column is confirmed present in the landing table after the migration,
without connector reconfiguration"; "affected models absorb the new column
automatically on the next run"; "live run: the migration is applied against a
running connector and the pipeline completes without intervention".

### Reversibility

`GAMES_ADD_COLUMN_REVERSE=true` ran `alter table games drop column if exists
early_access;` and the column count returned to 0 — the stack is back to its
prior shape with no teardown.

Discharges: #144 "the scenario is reversible, so the stack can be returned to
its prior shape without a teardown".

### The contract violation — the criterion with no offline path

#144's author established empirically that `dbt parse` does not validate
contract columns while `compile`/`build`/`run` all require a live Snowflake
connection, and deferred this criterion rather than claiming it. Demonstrated
here by adding an undeclared column to `fct_wishlist_items`:

```
This model has an enforced contract that failed.
| column_name                   | definition_type | contract_type | mismatch_reason     |
| UNDECLARED_CONTRACT_VIOLATION | FIXED           |               | missing in contract |
```

Build failed (`ERROR=1`). Reverted from backup; build green again (`PASS=4
ERROR=0`) and the working tree clean.

Discharges: #144 "a deliberate contract violation is demonstrated to fail the
build, then reverted".

**#144's live criteria are now all discharged.**

## Step — #138: the spec's restatement claim, tested and FALSIFIED

The parent spec asserts restatement needs "no new handling mechanism ... the
`merge` strategy and the lookback window cover it". #138's implementer declined
to tick that box, reasoning that `incremental_lookback_filter()` bounds on the
target table's own high-water mark rather than on "now", so a restatement
arriving far enough behind that mark is excluded *before* merge ever sees it.
That is the one place the spec's own reasoning could be silently wrong, so it got
a dedicated experiment.

High-water mark at the time: `2026-10-25 22:13`, giving a 14-day window floor of
`2026-10-11 22:13`.

Two restatements of already-revoked `ownership_grants` rows, each clearing
`revoked_at` and leaving `granted_at` (the event time) untouched — differing only
in arrival time:

**Case A — arrival inside the window** (`recorded_at = now()`):

```
 LABEL           | STG_RESTATED | FACT_RESTATED
-----------------+--------------+---------------
 A_inside_window |            1 |             1
```

**Case B — arrival behind the window floor** (`recorded_at = 2026-09-01`):

```
 LABEL          | STG_RESTATED | FACT_RESTATED | FACT_STILL_REVOKED
----------------+--------------+---------------+--------------------
 B_behind_floor |            1 |             0 |                  1
```

**The finding holds.** In Case B the staging view — which has no lookback filter
— shows the restatement correctly, while the fact still reports the grant as
revoked. The correction was **silently dropped**: no error, no warning, no retry.
A finance figure built on that fact stays wrong indefinitely while the pipeline
reports success.

The asymmetry with delete propagation is what makes the mechanism clear: delete
tombstones survive the same filter only because the integration review added an
explicit `is_deleted or ...` branch to the macro. Restatements have no equivalent
escape hatch, so they are gated purely on `recorded_at`.

Discharges: #138 "confirmed that a restatement older than the lookback window is
not picked up, and that limitation documented" — with the observed outcome being
the failure case, not the assumed success.

### Deliberately NOT "fixed"

Widening or removing the window would trade a bounded, monitored staleness for
an unbounded table scan on every run, and the spec already rejected the
alternative of shipping an undersized window precisely because "sizing a window
from observed lag and monitoring it is the standard practice". The correct
response is the one the spec already contains: #137's `fct_arrival_lag` monitors
observed lag against the configured window so the margin is visible before data
is lost. This result is the evidence that monitor is load-bearing rather than
decorative.

What was wrong was the spec's *claim* that merge plus the window needs no new
mechanism. It does not cover this case, and that is now written down instead of
assumed.

## Orchestration error — #133 was never merged

While setting up the generator cranks I noticed `duplicate_rate_purchases` was
absent from `terraform/variables.tf`, and `DUPLICATE_RATES` had no `purchases`
entry. `_insert_purchase` did a single insert with no duplicate roll.

`git merge-base --is-ancestor dfed54c HEAD` -> **not an ancestor**. Ticket #133
had never been merged, in either repo. One of the spec's seven fault classes —
business-key duplicates and the staging dedupe that collapses them — was absent
from the integration branch while I verified the other six. That is my error as
orchestrator; the ticket itself was complete and pushed.

Audited every ticket branch in both repos to establish the blast radius:

```
infra:     ticket-133 NOT MERGED; 130,131,132,136,138,139,140,142,143,144,
           rev-a,rev-b all merged
analytics: ticket-133 NOT MERGED; 132,134,135,136,137,139,141,143,144,145,
           rev-a,rev-b all merged
```

#133 was the only one.

### Merging it exposed an interaction nothing else could

Both #133 and #139 touch `_insert_purchase`. #139's two payment-method onset
tests build `FakeCursor(fetchone_values=[("purchase-1",)])` — a single id. #133
makes `_insert_purchase` insert a second row and call `fetchone()` again on a
duplicate hit, so across 200 iterations at the 2% rate those tests eventually
raised:

```
IndexError: pop from empty list
```

Each ticket's suite passed in isolation. Only the merge reveals it. Fixed by
giving those tests a second id, since their subject is the payment method rather
than duplication. 115 generator/scenario tests pass, `tofu validate` clean.

The analytics side conflicted on `fct_purchases`'s `purchased_at` column —
#144's contract `data_type` against #133's not-null guard — resolved by keeping
both, since #133's guard exists precisely because `NULL = NULL` matches in both
`qualify row_number()` and `unique_combination_of_columns` and would silently
merge unrelated purchases.

## Step — cranked rates: all five remaining faults, injected and handled

### Deviations from the runbook, stated up front

1. **One batched crank, not six serial ones.** The runbook called for cranking
   one knob at a time. Each fault lands on a distinct table/column, so
   attribution is unambiguous when measured per fault, and batching saved five
   generator instance replacements. Applied:
   `duplicate_rate_purchases=0.5`, `late_arrival_rate=1.0`,
   `late_arrival_max_days=20`, `payment_method_new_onset_date=2020-01-01`,
   `orphan_never_arrives_rate=0.3`, `orphan_late_arrival_rate=0.3`,
   `restatement_weight=5`.
2. **A defect in #130's plumbing had to be fixed first** — see below.
3. **CORRECTION.** My first measurement after the apply reported all five faults
   with plausible-looking counts. It was wrong: cloud-init was still installing
   Docker, the new generator had not started, and those rows were the OLD
   instance's default-rate output. Default rates over a couple of hours produce
   very similar numbers, which is why it looked convincing. Every figure below
   is scoped to `recorded_at > 22:33:00`, after the old instance stopped
   (confirmed by a 2m27s write gap) and the new one began.

### FINDING — the rate overrides did not reach the running generator

`aws_instance.generator` had no `user_data_replace_on_change`, which defaults to
`false`. EC2 user_data only ever executes at first boot, so changing any
injection rate and running `tofu apply` updated Terraform state and left the
running container on the environment it booted with. The plan said
`1 to change` (in-place) and would have been a silent no-op.

Every knob was therefore effectively bring-up-only, which defeats the spec's own
purpose for them: "a fault that normally takes days to appear can be forced to
appear in minutes during verification". Fixed by setting
`user_data_replace_on_change = true`; the plan then correctly became
`1 to add, 1 to destroy`, the instance was replaced, and the overrides took
effect. The generator is stateless and rebuilds its image on boot, so
replacement is the right trade.

### Injection, measured after the cutoff

| fault | evidence |
|-------|----------|
| #139 enum onset | `payment_methods_seen = credit_card, crypto, paypal, steam_wallet` |
| #133 business-key duplicates | **7 duplicate groups** in 18 purchases |
| #136 late arrival | **11 of 11** client events backdated |
| #140 orphans | **4 of 11** events referencing an absent user |

`crypto` reached the landing table (5 rows and climbing) with no schema change
and no connector reconfiguration.

### Handling — the pairs of numbers the spec asks for

**#133 — business-key dedupe**

```
landing purchase rows            985
staging after business-key dedupe 943   <- 42 duplicate rows collapsed
duplicate groups remaining         0
```

The wrong number is 985 rows of revenue; the right number is 943. Zero
business-key duplicate groups survive into the staging layer, and the
`unique_combination_of_columns` test on the fact passes.

**#139 — unknown bucket**

```
crypto rows in fct_purchases              15
of those, landing in the 'unknown' bucket 15
rows with a NULL bucket                    0
total revenue      32,421.66
bucketed revenue   32,421.66   <- reconciles exactly
```

An unrecognised enum value lands in an explicit bucket, never null, and
bucketed totals still sum to the unbucketed total.

**#140 -> #141 — orphan events**

```
unknown-member sentinel rows in dim_users    1
funnel sessions resolving to unknown member 14
total funnel sessions                      426
```

An inner join would have reported **412**; with the unknown member the count is
**426**. The 14 orphan sessions are retained instead of silently vanishing —
that is #140's wrong number and #141's corrected number.

### Detection — four independent mechanisms, each firing on its own fault

`dbt build`: `PASS=339 WARN=4 ERROR=0`. Every warning is a designed detector
catching a real injected fault, at warn severity, without failing the build:

```
WARN  1  accepted_values_fct_purchases_payment_method...   (#139 enum drift)
WARN 14  relationships_fct_product_funnel_sessions_...      (#141 orphan spike)
WARN  2  dbt_utils_expression_is_true_fct_arrival_lag_...   (#137 lag vs window)
WARN  2  elementary_volume_anomalies_fct_playtime_sessions  (#145 volume anomaly)
```

**#137's arrival-lag monitor, the reason the window is monitored rather than
assumed:**

```
 SOURCE_TABLE      | ARRIVAL_COUNT | MAX_LAG_DAYS | P95_LAG_DAYS | WINDOW | MARGIN_DAYS
-------------------+---------------+--------------+--------------+--------+-------------
 playtime_sessions |           482 |       19.673 |        7.622 |     14 |       6.378
 client_events     |           780 |       19.832 |        7.172 |     14 |       6.828
```

Max observed lag of **19.8 days against a 14-day window** — so late rows really
are falling outside it, which is exactly the data-loss condition this monitor
exists to make visible *before* the loss is noticed downstream. The warning
fired on #137's stated threshold (p95 lag eating more than half the window).
Max lag also stays under `late_arrival_max_days=20`, so #136's tail bound is
respected rather than unbounded.

Discharges live criteria on #133 (before/after revenue, dedupe), #136 (late rows
in landing and in the incremental fact, tail bound respected), #137 (monitor
reflects raised lag; warning fires when the tail is pushed past the window),
#139 (pre/post handling figures, warn-not-fail on drift), #140 (inner-join
discrepancy recorded), #141 (corrected count), and #145 (detection demonstrated
to fire by cranking a fault far above normal, alert captured).

## Step — #145: making detection quiet at default rates (recorded late; see note)

**Record-keeping note:** this section was written after the sub-issue closeout
began. The work was done and committed during verification, but I had recorded
it only in commit messages and in `LIVE-RUNBOOK.md`'s retraction, not here. The
closeout agent correctly declined to tick #145's criteria on the strength of
evidence that wasn't in this file. The gap was mine, not the ticket's.

### My planning error, retracted

The runbook's baseline-compression plan (override elementary's `time_bucket` to
5-minute buckets, turning a 7-14 hour baseline into ~90 minutes) is impossible:

```
time_bucket.period value should be one of ['hour', 'day', 'week', 'month'], got: minute
```

46 anomaly tests errored on that override. Retracted in `LIVE-RUNBOOK.md` rather
than deleted, with the replacement plan and an explicit fallback: if the window
could not be afforded, leave #145's live criteria undischarged with the reason
recorded rather than fake a baseline.

### Two causes of false positives at DEFAULT rates

With the invalid override removed, `dbt test` at default generator rates gave
`PASS=246 WARN=19`, with **18 volume-anomaly tests firing**. Two distinct causes:

1. **The in-progress bucket was being scored.** The stack was ~65 minutes old,
   so there were two hourly buckets and the partially-elapsed current hour
   looked like a volume collapse against the completed one. Fixed with a
   project-wide `detection_delay: { period: hour, count: 1 }` next to
   `time_bucket` in `dbt_project.yml` — never score the bucket still filling,
   which is the standard configuration and whose absence was the actual defect.

2. **Volume detection on bulk-seeded reference tables.** `users`, `games`,
   `game_prices` and `marketing_campaigns` are loaded once by `seed.py`;
   confirmed every row in all four shares the seed date:

   ```
    users               | 50008 | 2026-10-25 | 2026-10-25
    games               |  3000 | 2026-10-25 | 2026-10-25
    game_prices         | 15000 | 2026-10-25 | 2026-10-25
    marketing_campaigns |    40 | 2026-10-25 | 2026-10-25
   ```

   The test flags that one bucket and then has nothing to compare against. Volume
   detection removed on those four, with the reasoning recorded in place.

After both: `PASS=264 WARN=1 ERROR=0`, the single warning being the intended
orphan relationships warn from #140/#141.

### What this does and does not prove

- **"Detection demonstrated to fire by cranking one fault's rate far above
  normal": discharged.** `elementary_volume_anomalies_fct_playtime_sessions_started_at`
  fired `WARN 2` on the cranked run, alongside #137's lag monitor, #139's enum
  warn and #141's orphan warn.
- **"Detection demonstrated not to fire at default generator rates": discharged
  with a caveat that matters.** Zero anomaly tests fire at default rates after
  the two fixes. But with only one or two completed buckets of history,
  elementary is partly reporting *insufficient training data* rather than
  "scored this bucket and found it normal". Those are different claims and only
  the weaker one is proven.
- **"A baseline is recorded over a period of normal generator traffic": NOT
  discharged.** A trained baseline needs roughly `min_training_set_size`完整
  buckets — hours at the hourly granularity the project ships. This stack lived
  about 1h45m of default-rate traffic before rates were cranked. Honest outcome:
  left unticked. Deliberate narrowing of "configured across the staging layer"
  (four tables now have no volume test) is recorded on the issue.

## Reproducibility — teardown to $0, then up again from scratch

### Teardown #1 — the stack's own verdict

```
Stage 6/6 · Verify $0
  ✓ $0 verified — nothing billable left in AWS or Snowflake
✓ teardown complete
```

Independent sweep agreed: EKS, RDS, EC2, NAT, ELB, EBS all 0.

### Bring-up #2 — all seven stages green from zero

Completed every stage. Confirmed during it that
`snowflake_account_parameter.timezone` was **restored from IaC**:

```
TIMEZONE   UTC   America/Los_Angeles   ACCOUNT
```

This matters because teardown destroys that resource along with the Snowflake
databases, resetting the account default. The UTC fix is therefore reproducible
from code, not a manual `alter` left behind on the account.

### The dead-man's switch fired, and worked

The usage limit cut this session off with bring-up #2's full stack live — EKS,
RDS, NAT, bastion and generator — before the schema re-checks could run. The
detached watchdog noticed its deadline lapse and ran teardown itself:

```
2026-10-26T01:30:47Z teardown finished green
  ✓ $0 verified — nothing billable left in AWS or Snowflake
```

No session, no human, no intervention. The guard that had been a plan for the
whole of this spec is now demonstrated behaviour.

### Bring-up #3 — schema reproducibility, cheaply

Because the watchdog reclaimed bring-up #2 before its schema checks, those were
re-run on a third from-scratch database using `bringup.sh --stop-after 4`, which
brings up Snowflake, the VPC/RDS/bastion and the database stage but **not** EKS —
the schema lands in stage 4, so the expensive half was never needed.

Replication prerequisites on the fresh database:

```
  ✓ wal_level=logical
  ✓ steam_proj_admin has rds_replication
  ✓ steam_proj_admin has SELECT on all 16 captured tables
```

Schema facts:

```
 users_new_cols      | deletion_executed_at nullable=YES | deletion_requested_at nullable=YES
 client_events_fks   | client_events_game_id_fkey
 ce_user_id_nullable | NO
 early_access_absent | 0
```

- both new `users` columns land again, nullable;
- the `client_events` -> `users` foreign key is absent again while the `game_id`
  key survives, so #140's drop is targeted and reproducible;
- `user_id` is still `NOT NULL`;
- `early_access` is **correctly absent** — #144 deliberately kept it out of
  `db/schema.sql`, because the scenario models an upstream change the warehouse
  never heard about. A fresh database not having it confirms that decision
  rather than revealing a gap.

Three independent from-scratch databases now agree. The schema-guard-gated
changes are reproducible, not true once.
