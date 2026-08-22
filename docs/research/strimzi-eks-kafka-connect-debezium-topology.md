# Strimzi / Kafka Connect / Debezium topology on EKS

Research for [#32](https://github.com/Dulain-Willis/steam-infra/issues/32), child of the map issue [#27](https://github.com/Dulain-Willis/steam-infra/issues/27) (CDC Ingestion Pipeline: RDS -> Debezium -> Kafka -> Warehouse Sink).

Scope: this covers cluster topology, resource sizing, the plugin-image build question, EC2 sizing, and Debezium/RDS/EKS gotchas — for a **per-session, ephemeral, single-tenant learning cluster** that does a full Debezium snapshot of all 14 source tables on every spin-up. It does not revisit whether Strimzi/EKS is the right choice; that's the stated learning goal.

---

## 1. Cluster topology and sizing

### Broker count: single broker, KRaft mode, no ZooKeeper

Strimzi has removed ZooKeeper support in current releases (KRaft is the only mode in the two most recent Strimzi majors) — set up as a `KafkaNodePool` with combined `controller,broker` roles, one replica. There's no availability requirement here (topics are already accepted as disposable on teardown), so there's nothing multi-broker sizing would buy — it would only add another JVM's worth of memory overhead for zero benefit in a single-session, single-consumer-group workload.

- Strimzi ships an example single-node KRaft manifest (`examples/kafka/kraft/kafka-single-node.yaml` in the strimzi-kafka-operator repo) — good starting point.
- Combined controller+broker role in one pool avoids running a second pod purely for quorum, which matters more at this scale than in production (where controller/broker separation is recommended for isolation).

### Resource requests (starting point, not tuned)

| Component | CPU request | Memory request | Notes |
|---|---|---|---|
| Kafka broker (combined w/ controller) | 500m–1000m | 1.5–2Gi | JVM heap via `-Xms512m -Xmx1024m` in `.spec.kafka.jvmOptions`, leaving headroom for page cache |
| Kafka Connect worker | 500m | 1–1.5Gi | One worker, one task per connector is plenty at this volume; Debezium connector JVM heap can stay small (14 tables, snapshot-then-stream, not high throughput) |
| Entity/Topic/User operators (Strimzi control plane pods) | 100m–200m each | 256–384Mi each | Fixed overhead regardless of workload size, budget for it |

Set requests == limits only if you want the pod QoS to be `Guaranteed`; for a learning cluster that gets torn down, `Burstable` (requests only, generous limits) is fine and cheaper to reason about. Strimzi does **not** set CPU/memory requests/limits by default — you must set them explicitly in `Kafka`/`KafkaNodePool`/`KafkaConnect` `.spec.resources`, or pods get no resource guarantees at all.

### KRaft controller quorum

With a single combined node there's no separate quorum to size. If a future iteration splits controller and broker roles, controllers are lighter (500m/1Gi is a reasonable floor) since they only manage metadata, not partition data.

Sources:
- [Strimzi: Deploying and Managing (latest)](https://strimzi.io/docs/operators/latest/deploying) — resource configuration, KRaft node pools
- [Strimzi: Configuring (latest)](https://strimzi.io/docs/operators/latest/configuring)
- [Red Hat: minimum sizing guide for OpenShift dev environment](https://access.redhat.com/solutions/4205851)
- [strimzi/strimzi-kafka-operator examples/kafka/kraft](https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/kafka/kraft)

---

## 2. Getting Debezium (and later, a sink connector) into Strimzi's KafkaConnect

Two real options; a third ("mount a PVC with the jars") is a Strimzi anti-pattern and not covered.

### Option A — Strimzi's built-in image build (`KafkaConnect.spec.build`)

You declare the connector plugins and their download URLs in `.spec.build.plugins`, and point `.spec.build.output` at a registry (Docker Hub, ECR, or an internal `ImageStream` on OpenShift). The Cluster Operator then:

1. Generates a `Dockerfile` from your plugin list.
2. Runs a one-shot build pod using **Kaniko** (a daemonless, unprivileged container builder — no Docker-in-Docker, no privileged pod needed, which matters on EKS where you don't want to grant that).
3. Pushes the resulting image to your configured registry.
4. Rolls the `KafkaConnect` deployment to use the new image.

This happens automatically whenever the `KafkaConnect` CR's build spec changes, and Strimzi tracks a build revision so it skips rebuilding on every reconcile if nothing changed.

Sources:
- [Strimzi proposal 015: Kafka Connect Build](https://github.com/strimzi/proposals/blob/main/015-kafka-connect-build.md)
- [Strimzi blog: Building your own Kafka Connect image with a custom resource](https://strimzi.io/blog/2021/03/29/connector-build/)
- [Strimzi Build API reference](https://github.com/strimzi/strimzi-kafka-operator/blob/main/documentation/api/io.strimzi.api.kafka.model.connect.build.Build.adoc)

### Option B — Hand-build a Docker image with plugins baked in, push to ECR

You write a `Dockerfile FROM quay.io/strimzi/kafka:<version>-kafka-<kafka-version>`, `COPY` or `curl` the Debezium Postgres connector (and later sink connector) jars into `/opt/kafka/plugins/<name>/`, build it yourself (locally or in CI), push to ECR, and point `KafkaConnect.spec.image` at that ECR URI with `build` omitted entirely.

### Which one for this project

**Option B (hand-built image → ECR)**, for this project specifically:

- The project already has an ECR-shaped AWS setup (per `tofu destroy`/AWS-native discipline implied by the existing infra) — pushing one more image there is zero new infrastructure, whereas Strimzi's build mechanism needs its own registry credentials wired into the `KafkaConnect` CR (`spec.build.output.pushSecret`) and a Kaniko build pod running inside the cluster on every startup, which is one more moving part to debug in a cluster that's rebuilt every session.
- Because the cluster is destroyed and recreated per session, Option A would re-run the Kaniko build (downloading the Debezium connector archive fresh, ~100+ MB) on every single spin-up before Connect can even start — pure wasted time and a new failure point (registry auth, download flakiness) on the critical path of every session start. A pre-built image sitting in ECR pulls instantly.
- The plugin set here is small and stable (Debezium Postgres connector + one sink connector) and won't be edited interactively/iteratively the way Strimzi's build flow is optimized for (fast local plugin-list tweaks without hand-rolling Dockerfiles). Rebuilding the image is a rare, deliberate action (bump Debezium version), not a per-session concern — so the extra one-time authoring cost of a Dockerfile pays for itself in per-session startup speed and one fewer runtime dependency (no in-cluster Kaniko build pod, no build-time registry push credentials needed inside the cluster).
- Trade-off going in: you own rebuilding/pushing the image when you bump the Debezium version, and CI (or a local `docker build && docker push`) needs to run before `tofu apply`/session start rather than the cluster doing it itself. That's an acceptable manual step for a project already OK with manual `tofu apply`/`destroy` cycles.

If the plugin set were expected to churn a lot, or if there were no existing registry/CI story, Option A would be the lower-effort choice — flag this as a decision to revisit if the sink connector work turns out to need frequent rebuilds.

---

## 3. EC2 / node group sizing on EKS

Budgeting for: 1 Kafka broker pod (~1 CPU / 2Gi), 1 Connect worker pod (~0.5 CPU / 1.5Gi), Strimzi operator + 3 small operator sidecars (Topic/User/Entity operator, ~0.3 CPU / 1Gi combined), plus the Strimzi Cluster Operator itself if it runs in-cluster, plus EKS system pods (CoreDNS, kube-proxy, aws-node) — call system overhead ~0.5 CPU / 0.5Gi.

That's roughly 2.5–3 vCPU and 5–6Gi memory total, comfortably inside a single mid-size node with room for pod overhead/eviction thresholds:

- **`t3.large`** (2 vCPU, 8Gi) or **`t3a.large`** — burstable, cheap, fine for a bursty snapshot-then-idle workload; CPU credits handle the snapshot burst at startup and idle afterward.
- **`m6g.large` (Graviton, 2 vCPU/8Gi)** if arm64 is acceptable — Strimzi ships official arm64 images, and Graviton is commonly cited as ~20–30% better price/performance for Kafka-shaped workloads. Worth it only if the rest of the stack (connector images, generator) is already multi-arch or arm64-friendly; not worth introducing arch complexity just for this ticket.
- A **single-node managed node group** is enough — no need for multi-AZ or multiple nodes given the single-broker, no-HA topology decided above. Keep it to one node to avoid EKS's per-node overhead (extra EBS volumes, extra CNI IPs) for no redundancy benefit.

Rule of thumb from the AWS EKS-on-Kafka blog and cost writeups: t3.medium (2 vCPU/4Gi, ~$30/mo if left running) is workable but tight once you add the operator pods and EKS system daemonset overhead — t3.large gives slack without materially changing the per-session cost, since sessions are short-lived and torn down.

Sources:
- [AWS: Deploying and scaling Apache Kafka on Amazon EKS](https://aws.amazon.com/blogs/containers/deploying-and-scaling-apache-kafka-on-amazon-eks/)
- [Data on Kubernetes: Strimzi for running Apache Kafka](https://seifrajhi.github.io/blog/data-on-kubernetes-strimzi-kafka-6/)
- [AWS: MSK clusters with T3 brokers for less than $2.50/day](https://aws.amazon.com/about-aws/whats-new/2020/04/create-amazon-msk-clusters-with-t3-brokers) (useful cost baseline even though it's MSK not Strimzi)

---

## 4. Debezium/Strimzi/EKS gotchas

### Postgres logical decoding plugin: use `pgoutput`, not `decoderbufs`

`pgoutput` is the standard, built-in logical decoding output plugin present in Postgres 10+ (and thus in RDS Postgres by default) — no extra extension install needed. `decoderbufs` requires installing a Debezium-maintained native extension, which **you cannot do on RDS** (no superuser/filesystem access to add extensions outside RDS's supported list). This makes `pgoutput` effectively mandatory on RDS, not just a preference. Set `plugin.name: pgoutput` in the connector config.

Source: [Debezium docs: Logical Decoding Output Plug-in Installation for PostgreSQL](https://debezium.io/documentation/reference/stable/postgres-plugins.html)

### RDS-specific setup requirements

- **Parameter group**: the RDS instance needs a custom (non-default) DB parameter group with `rds.logical_replication = 1`. This forces `wal_level=logical` and sets `max_wal_senders`/`max_replication_slots` appropriately — RDS manages these via the parameter group, not `postgresql.conf` directly. **Changing this parameter requires a reboot** of the instance — worth doing once at RDS provisioning time (in the terraform), not something to discover mid-session.
- **`rds_replication` role**: the connecting Postgres user needs `GRANT rds_replication TO <user>;` (RDS's substitute for superuser-only `REPLICATION` privilege) plus normal `SELECT` on the tables being captured.
- **Replication slot lifetime**: since a fresh full snapshot is taken every session, make sure the connector is configured to create a **new, uniquely-named slot per session** (or explicitly drop the old slot on teardown) — a stale slot left behind after a `tofu destroy` will pin WAL on the RDS instance indefinitely, growing storage silently until intervention. Because state loss is accepted here, actively drop the slot as part of teardown rather than relying on Debezium's own defaults — Debezium does not delete the slot on connector removal.
- **`snapshot.mode`**: use `always` or `initial` per session semantics — since a fresh snapshot is wanted every time (no offset persistence is being kept across sessions anyway), the simplest correct choice is `snapshot.mode: always` (or `initial` combined with always destroying the slot/offsets topic so it acts fresh). Document this explicitly in the connector config so it isn't accidentally left as an incremental-resume mode that then does nothing because there is no prior offset.

Source: [Debezium: RDS.md](https://github.com/debezium/debezium/blob/main/debezium-connector-postgres/RDS.md), [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)

### Networking: EKS pods → RDS across the VPC

- Straightforward if the EKS node group and the RDS instance are in the **same VPC** (likely already true for this project) — the main failure mode is the **RDS security group not allowing inbound from the EKS node/pod security group** on port 5432. Add an inbound rule on the RDS SG allowing the EKS node security group (or a dedicated SG attached via Security Groups for Pods, if used) on 5432.
- If RDS is in private subnets and EKS nodes are too, no NAT/IGW is needed for this path — it's an intra-VPC route. Only outbound internet access (image pulls, connector-jar downloads under Option A) needs NAT.
- DNS: use the RDS endpoint hostname, not a hardcoded IP — RDS IPs can change on failover/maintenance.

Source: [AWS re:Post: Connect from Amazon EKS to other services](https://repost.aws/knowledge-center/eks-connect-other-services)

### Strimzi CRD/version gotchas

- Strimzi's `Kafka`/`KafkaNodePool`/`KafkaConnect` CRDs change shape across Strimzi minor versions (e.g. the KRaft `KafkaNodePool` API stabilized over several releases, and ZooKeeper-mode fields were removed entirely in current releases) — pin the Strimzi operator version in terraform/helm and don't assume examples from older blog posts apply verbatim; check the CRD reference for the pinned version.
- `KafkaConnector` (the CR for individual connectors, e.g. the Debezium Postgres source connector) requires the `strimzi.io/use-connector-resources: "true"` annotation on the `KafkaConnect` resource, or Strimzi won't reconcile `KafkaConnector` CRs at all — a common "why isn't my connector starting" trap.
- Kaniko build pods (Option A, if ever used) need outbound internet access to pull base images and plugin archives — will fail silently/hang in a fully private subnet with no NAT.

---

## Recommendation summary

- **Topology**: single-node KRaft `Kafka` (combined controller+broker), one Kafka Connect worker, Strimzi Topic/User/Entity operators as usual. No ZooKeeper, no multi-broker HA — matches the accepted state-loss-on-teardown decision.
- **Sizing**: ~1 CPU/2Gi for the broker, ~0.5 CPU/1.5Gi for Connect, running on a single `t3.large` (or `m6g.large` if arm64 is embraced project-wide) node group.
- **Plugin delivery**: hand-build a Dockerfile-based image with Debezium Postgres connector (+ sink connector later) baked in, push to ECR, reference via `KafkaConnect.spec.image`. Skip Strimzi's Kaniko-based `spec.build` — it re-downloads/rebuilds on every session start, which is pure overhead for a stable, infrequently-changed plugin set in a project that already has ECR.
- **Debezium config**: `plugin.name: pgoutput`, RDS parameter group with `rds.logical_replication=1`, `rds_replication` role grant, `snapshot.mode: always`, explicit replication-slot cleanup on teardown to avoid orphaned WAL retention on RDS.

**Confidence**: high on the mechanics (Strimzi build vs. custom image, pgoutput requirement, RDS role/parameter-group requirements are all directly documented behavior); medium on exact sizing numbers (no benchmark was run against this project's actual 14-table snapshot volume — treat the CPU/memory figures as a starting point to adjust after watching one real session's resource usage, not a hard spec).
