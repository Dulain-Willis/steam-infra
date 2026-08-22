# Warehouse pick: Snowflake vs self-hosted ClickHouse

Research for issue #30 (child of map #27, "CDC Ingestion Pipeline: RDS -> Debezium -> Kafka -> Warehouse Sink").

Scope: pick the CDC sink target by **cost + simplicity**, not as a second learning
goal. EKS/Strimzi/Kafka Connect/Debezium are fixed and out of scope here.

## 1. Terraform support

### Snowflake

- Official provider: [`snowflakedb/snowflake`](https://registry.terraform.io/providers/snowflakedb/snowflake/latest/docs),
  maintained by Snowflake itself, source at
  [github.com/snowflakedb/terraform-provider-snowflake](https://github.com/snowflakedb/terraform-provider-snowflake).
  Currently at v2.19.x; officially supported (stable resources) starting at v2.0.0.
- Also documented directly by Snowflake:
  [docs.snowflake.com/en/user-guide/terraform](https://docs.snowflake.com/en/user-guide/terraform) and a
  guided walkthrough at [snowflake.com/en/developers/guides/terraforming-snowflake](https://www.snowflake.com/en/developers/guides/terraforming-snowflake/).
- Provisions: databases, schemas, warehouses (including size, auto-suspend, auto-resume),
  users, roles, grants, resource monitors, network policies, integrations (incl. the
  Kafka/Snowpipe Streaming plumbing), tables, and more. This is a full, first-class
  provider — not a thin community wrapper.
- **Verdict: yes, well-maintained, official, covers everything needed here (db, warehouse, user/role, grants).**

### ClickHouse (self-hosted)

- Official provider: [`ClickHouse/terraform-provider-clickhouse`](https://github.com/ClickHouse/terraform-provider-clickhouse) —
  but this targets **ClickHouse Cloud** control-plane resources (services, API keys,
  networking), not a self-hosted box. Not useful for an EC2/Docker deployment.
- A separate provider, `clickhousedbops`, exists specifically for managing
  **database-level** objects (users, roles, grants) against a self-hosted or
  on-prem ClickHouse instance — see the ClickHouse blog post
  ["New Terraform provider: Manage ClickHouse database users, roles, and privileges with code"](https://clickhouse.com/blog/new-terraform-provider-manage-clickhouse-database-users-roles-and-privileges-with-code).
  This is much newer/thinner than the Snowflake provider and only covers
  users/roles/grants — not "install and configure ClickHouse itself."
- For the actual host: there's no ClickHouse-specific "provision the server"
  provider. Self-hosted ClickHouse-on-EC2 is provisioned the same way any other
  self-hosted service would be — plain `aws` provider resources (EC2 instance,
  security group, EBS volume) plus a `user_data` bootstrap script or a
  `docker-compose.yml` pushed via cloud-init/Ansible/SSH provisioner to run the
  official `clickhouse-server` Docker image. This is standard IaC, not a gap,
  but it means **you own the "warehouse itself" as infrastructure**, not just
  as a logical resource inside someone else's control plane.
- **Verdict: no purpose-built "stand up self-hosted ClickHouse" provider.** You get
  generic `aws` Terraform (well-trodden, fine) for the box, and a young
  `clickhousedbops` provider for in-database objects if you want that level of
  polish. Reasonable, but noticeably less turnkey than Snowflake's.

## 2. Free, open-source Kafka Connect sink connectors

### Snowflake

- [`snowflakedb/snowflake-kafka-connector`](https://github.com/snowflakedb/snowflake-kafka-connector) is
  **Apache License 2.0**, built and maintained by Snowflake, distributed as a
  standard fat JAR for plain Apache Kafka Connect (a separate build variant
  exists for Confluent Platform, but the OSS/Apache Kafka version needs no
  Confluent license or paid tier). See
  [docs.snowflake.com/en/user-guide/kafka-connector-overview](https://docs.snowflake.com/en/user-guide/kafka-connector-overview)
  and [kafka-connector-install](https://docs.snowflake.com/en/user-guide/kafka-connector-install).
- Auth is key-pair based (RSA key pair registered on the Snowflake user), not
  password — a bit more setup than a plain JDBC sink, but well documented and
  scriptable from Terraform (the provider can set the user's public key).
- **Verdict: free and Apache-2.0, no Confluent tier required.**

### ClickHouse

- Two credible open-source options:
  - [`ClickHouse/clickhouse-kafka-connect`](https://github.com/ClickHouse/clickhouse-kafka-connect) —
    the official ClickHouse-maintained sink connector, Apache-2.0.
  - [`Altinity/clickhouse-sink-connector`](https://github.com/Altinity/clickhouse-sink-connector) —
    Altinity-maintained, Apache-2.0, notably **purpose-built for CDC**: it
    understands Debezium-shaped change events out of the box (MySQL/Postgres/
    MongoDB -> ClickHouse) with insert/update/delete handled via
    `ReplacingMergeTree`, which maps directly onto this project's
    Debezium-CDC use case. See the
    [architecture doc](https://github.com/Altinity/clickhouse-sink-connector/blob/develop/doc/architecture.md)
    and [v2.0 announcement](https://altinity.com/blog/announcing-version-2-0-of-the-altinity-clickhouse-sink-connector).
- **Verdict: free and Apache-2.0, and arguably better CDC ergonomics than the generic connector** (Altinity's is explicitly designed around Debezium-style change events, closer to this pipeline's shape than Snowflake's generic sink).

## 3. Cost profile (teardown-between-sessions usage)

Both sides of this comparison already assume `tofu destroy` when idle, so
storage-at-rest and steady 24/7 compute aren't the concern — only the cost
**while a session is actively running**.

### Snowflake

- New accounts get a **free trial: $400 in credits, valid 30 days** from
  signup, whichever is exhausted first (per
  [Snowflake trial account docs](https://docs.snowflake.com/en/user-guide/admin-trial-account)).
- Smallest compute unit, an **X-Small warehouse, burns 1 credit/hour**.
  On-demand AWS US-East Standard-edition credits run ~$2/credit (Enterprise
  ~$3, Business Critical ~$4) as of Aug 2026 pricing pages (Flexera/Markaicode
  roundups). So X-Small is roughly **$2-4/hour while running**, and
  effectively **free for a long time on trial credits** — $400 covers
  100-200 hours of X-Small compute even before the trial clock runs out.
- Warehouses **auto-suspend** (default 10 min idle, can be set to as low as
  ~1 min) and **auto-resume** on query, so per-session cost is naturally
  bounded to actual active time, independent of whether you also run
  `tofu destroy`. Storage cost for the tiny data volumes here is negligible
  ($/TB/month, this project is nowhere near a TB).
- **Net: effectively $0 out of pocket for a learning project of this size, for at least the first ~30 days / ~150 warehouse-hours.** After the trial, ~$2-4/hr while the warehouse is actually running.

### Self-hosted ClickHouse on EC2

- ClickHouse itself has no license cost (Apache 2.0), so cost = EC2 instance
  (+ EBS + minor data transfer).
- A reasonable minimum size for single-node ClickHouse serving a small
  14-table CDC feed is something like `t3.medium` (2 vCPU / 4 GiB) up to
  `t3.large` (2 vCPU / 8 GiB) if ClickHouse's memory appetite gets tight.
  On-demand `t3.medium` in us-east-1 is about **$0.0416/hour**
  ([economize.cloud](https://www.economize.cloud/resources/aws/pricing/ec2/t3.medium/),
  [Vantage](https://instances.vantage.sh/aws/ec2/t3.medium)); `t3.large` is
  roughly double that, ~$0.083/hour. Add a small EBS gp3 volume (a few GB,
  fractions of a cent/hour) and negligible data transfer for a personal
  project.
- With teardown-between-sessions, **cost is effectively pay-per-session**:
  a few cents per hour of actual use, no free-trial clock, no eventual
  "trial expires" cliff — this is genuinely cheaper in raw dollar terms
  than Snowflake once the $400 credit runs out, though at this project's
  scale both are close to rounding errors (a few dollars a month either way
  under a teardown-when-idle pattern).
- **Net: cents/hour, no time-boxing, but 100% self-managed** — no
  autosuspend/autoresume equivalent exists; if you forget `tofu destroy`,
  the box just keeps billing (and needs monitoring/patching while it runs).

## 4. Other practical gotchas

- **Snowflake trial time-boxing**: the $400/30-day trial is a one-time deal
  tied to the account. Once it expires (by day-count or credit exhaustion),
  you're on a real credit card for even the smallest warehouse-hour, so this
  is a fine fit for an initial learning burst but not a truly indefinite free
  ride the way "tear it all down when idle" implies for a self-hosted option.
- **ClickHouse operational overhead**: self-hosting means you own OS patching,
  ClickHouse version upgrades, disk sizing, backup/restore (if ever wanted),
  and crash recovery. For a from-scratch EC2+Docker box torn down between
  sessions this is fairly low-stakes (no persistent state to protect if
  Terraform rebuilds it each time), but it's still real "second thing to
  learn and babysit" versus Snowflake managing all of that for you.
- **Network/auth complexity from EKS-hosted Kafka Connect**:
  - *Snowflake*: outbound HTTPS from the EKS worker nodes to
    `*.snowflakecomputing.com` (no inbound ports to open, no VPC peering
    needed) plus key-pair auth (generate an RSA key, register the public key
    on the Snowflake user — scriptable via the Terraform provider, private
    key goes into the Connect worker as a secret). Simpler network story
    since Snowflake is already internet-reachable.
  - *ClickHouse on EC2*: needs a **security group rule allowing inbound
    traffic from the EKS nodes' security group/CIDR** to ClickHouse's
    HTTP/native ports (8123/9000), and if the EC2 box and EKS cluster are in
    different VPCs, VPC peering or at least care around routing/NACLs. Auth
    is simpler (plain user/password or mTLS if you want to invest in it) but
    the network reachability setup is the extra step Snowflake avoids by
    being a SaaS endpoint.
  - Both are one-time Terraform-scriptable setups, but ClickHouse's is a
    "stand up a reachable, secured Layer 3/4 endpoint" problem on top of the
    Kafka Connect config, where Snowflake's is purely an application-layer
    auth problem.

## Recommendation

**Snowflake**, for this project's stated goal (cost + simplicity, not a second
learning target):

- Terraform support is more mature and purpose-built for what's needed here
  (db/warehouse/user/role all first-class, official provider).
- The Kafka sink connector is free/Apache-2.0 either way, so licensing isn't
  a differentiator.
- Cost is a wash at this scale ($2-4/hr on Snowflake vs. cents/hr on EC2, but
  both round to "a few dollars a month" under a teardown-when-idle pattern),
  and the $400/30-day trial likely covers the entire active learning phase
  of this project for free.
- Simplicity tips it: no box to patch, no security-group/VPC-peering
  reachability problem from EKS, autosuspend/autoresume matches the
  teardown-between-sessions usage pattern natively instead of needing you to
  remember to tear it down. ClickHouse's ergonomic edge (Altinity's connector
  understands Debezium CDC shapes natively) is real but doesn't outweigh
  "one less service to operate."

Confidence: **medium-high**. The facts checked out consistently across
multiple sources (official docs, GitHub repos, and 2026 pricing roundups),
but exact per-credit and per-instance pricing can drift, and the "cost is a
wash" conclusion depends on how many active hours/month this project
actually racks up — if usage grows well past the trial's ~150 warehouse-hours,
ClickHouse's raw per-hour cost advantage becomes more meaningful, at the cost
of ongoing self-management.

## Sources

- [Snowflake Terraform provider — Terraform Registry](https://registry.terraform.io/providers/snowflakedb/snowflake/latest/docs)
- [Snowflake Terraform provider — Snowflake docs](https://docs.snowflake.com/en/user-guide/terraform)
- [terraform-provider-snowflake GitHub](https://github.com/snowflakedb/terraform-provider-snowflake)
- [Terraforming Snowflake guide](https://www.snowflake.com/en/developers/guides/terraforming-snowflake/)
- [ClickHouse Terraform provider (Cloud) GitHub](https://github.com/ClickHouse/terraform-provider-clickhouse)
- [New Terraform provider: manage ClickHouse users/roles/privileges (clickhousedbops)](https://clickhouse.com/blog/new-terraform-provider-manage-clickhouse-database-users-roles-and-privileges-with-code)
- [Snowflake Kafka Connector overview](https://docs.snowflake.com/en/user-guide/kafka-connector-overview)
- [Snowflake Kafka Connector install/config](https://docs.snowflake.com/en/user-guide/kafka-connector-install)
- [snowflake-kafka-connector GitHub (Apache-2.0)](https://github.com/snowflakedb/snowflake-kafka-connector)
- [ClickHouse/clickhouse-kafka-connect GitHub](https://github.com/ClickHouse/clickhouse-kafka-connect)
- [Altinity/clickhouse-sink-connector GitHub](https://github.com/Altinity/clickhouse-sink-connector)
- [Altinity sink connector architecture doc](https://github.com/Altinity/clickhouse-sink-connector/blob/develop/doc/architecture.md)
- [Altinity Sink Connector v2.0 announcement](https://altinity.com/blog/announcing-version-2-0-of-the-altinity-clickhouse-sink-connector)
- [Snowflake trial account docs ($400/30 days)](https://docs.snowflake.com/en/user-guide/admin-trial-account)
- [Snowflake pricing 2026 — Flexera](https://www.flexera.com/blog/finops/ultimate-snowflake-cost-optimization-guide-reduce-snowflake-costs-pay-as-you-go-pricing-in-snowflake/)
- [Snowflake pricing (Aug 2026) — Markaicode](https://markaicode.com/pricing/snowflake-pricing/)
- [EC2 t3.medium pricing — economize.cloud](https://www.economize.cloud/resources/aws/pricing/ec2/t3.medium/)
- [EC2 t3.medium pricing — Vantage](https://instances.vantage.sh/aws/ec2/t3.medium)
