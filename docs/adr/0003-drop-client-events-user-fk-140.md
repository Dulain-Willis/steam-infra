# ADR 0003: drop the client_events-to-users foreign key from #140

## Status

Accepted.

## Context

`db/schema.sql` declared `client_events.user_id uuid not null references
users(id)` from the table's introduction (steam-analytics#12) onward, along
with every other foreign key in the schema. That followed the schema's
default: every relationship gets a database-enforced FK unless there is a
specific reason not to.

This schema models a single OLTP database for a toy platform, but the
platform it's modelling is not a single service. In a real Steam-shaped
architecture, client-side funnel events are owned by a product-analytics /
telemetry service, and user accounts are owned by a separate identity
service, each with its own database. No database can enforce a foreign key
across that boundary — there is no cross-service `REFERENCES`. A
same-database FK here was quietly asserting an architecture (one shared
database for events and accounts) that the rest of this project's design
doesn't have.

The consequence of keeping the FK: `client_events.user_id` can never
reference a user that hasn't landed yet, or that never will — which is
exactly the shape a cross-service event pipeline has to tolerate in
production (events can arrive before, or without, their owning account).
The database was enforcing an invariant the real system can't actually
guarantee.

## Decision

Drop the foreign key. `client_events.user_id uuid not null` keeps the
column itself non-nullable — an event is still never anonymous — but
Postgres no longer checks that the id it holds exists in `users`.

Integrity moves from database-enforced to **warehouse-enforced**: it
becomes something steam-analytics monitors (a dbt test / metric on the
inner-join discrepancy between `client_events` and `users`) rather than
something Postgres rejects at insert time. The generator (#140) now
deliberately emits orphaned `client_events` rows in two flavours — a parent
that never arrives, and one that arrives a short time later — so that the
discrepancy, and its self-healing on the late-arrival case, is a real,
observable signal rather than a hypothetical.

## Considered options

- **Keep the FK.** Rejected: it models an architecture (one shared database
  for events and accounts) this project doesn't have, and it makes it
  impossible to generate the exact failure mode (orphaned events) the
  warehouse needs to learn to detect and tolerate. Keeping it would also
  block #140/#141's whole point, which is to make the shrinking-event-count
  symptom real and then fix it downstream.
- **Keep the FK but make it `deferrable initially deferred`.** Rejected:
  this still requires the referenced user to exist by transaction commit,
  which rules out the "never arrives" flavour and the realistic case where
  the account service's write genuinely never happens. It only buys
  same-transaction ordering slack, not cross-service tolerance.
- **Drop the FK and make the column nullable too.** Rejected by the ticket
  itself: nullability and referential integrity are separate questions. An
  event is still always attributed to *some* user id; the column just can no
  longer promise that id resolves to a row in this database.

## Consequences

- `db/schema.sql`'s `client_events` table comment now explains the
  cross-service reasoning inline, since this is the one FK in the schema
  that's intentionally absent rather than simply not-yet-added.
- The schema change only takes effect on a from-scratch bring-up:
  `scripts/lib/schema_guard.py` applies `schema.sql` only when the schema is
  absent, and there is no migration runner in this repo. An already-running
  dev database keeps the old FK until it is torn down and rebuilt.
- steam-analytics gains a monitoring obligation it didn't have before: the
  inner-join discrepancy between `client_events` and `users` is now a real
  possibility that needs a dbt test/metric, not a case Postgres rules out.
  #141 is the ticket that adds the handling; #140 only establishes that the
  discrepancy is real and records its magnitude.
- `CONTEXT.md`'s glossary gains an entry for this relationship so "why
  doesn't this table have an FK to users" has a documented answer instead of
  looking like an oversight.
