# seatunnel-spark → UBI9 migration review

Status: **draft** (2026-09-01). Findings below are measured; the "after-build" numbers for the new image are still pending (see TODO in the PR).

Context: issue [#69](https://github.com/nq-rdl/container-images/issues/69) / dataops#139 Phase B — publish a prebuilt, digest-pinnable
replacement for `localdev/seatunnel-spark:2.3.13` (built today by `dataops/local-dev/seatunnel/{Dockerfile,connectors.txt}` from
`apache/spark:3.3.1`), and decide whether it should be rebased onto UBI9 like the rest of the catalog.

## TL;DR

- **Migrate to UBI9: yes.** The incumbent base is an unrebuilt 2022 image: Debian 11 (LTS ended 2026-08-31) + OpenJDK 11.0.16
  installed as a tarball, so its 16 missed quarterly JDK CPUs are invisible to Trivy. The catalog policy already fails on the one
  non-UBI image (`datascience-notebook-cuda`); adding a second exception is the worse option.
- **Java: Azul Zulu 11 JRE (11.0.32.1)**, not UBI's OpenJDK 11 (frozen at 11.0.25 since Oct 2024 — Red Hat's free OpenJDK 11
  support ended) and not Java 17 by default (SeaTunnel 2.3.13 officially supports Java 8/11 only). Java 17 is a validated
  build-arg path (`ZULU_MAJOR=17`).
- **Proven empirically on UBI9-minimal** with both Zulu 11.0.32.1 and Red Hat OpenJDK 17.0.20.1, no script changes:
  Zeta local (`seatunnel.sh -m local`), Zeta cluster (`seatunnel-cluster.sh` + client submit), Spark 3.3.1 local
  (`spark-submit … SeaTunnelSpark` and the upstream wrapper), and JDBC driver load for mssql-jdbc 12.8.1.jre11 / mysql-connector-j 8.4.0.
- **Zulu catalog images: the pattern yes, chaining no.** `zulu17/21-*-ubi9` force Java 17/21 and the chained-image bake/repin
  machinery; the Azul-repo recipe is copied instead (a future `zulu11-jre-headless-ubi9` image is possible).

## How dataops uses the image (the drop-in contract)

| Mode | How | User |
|------|-----|------|
| spark-operator `SparkApplication` (charts `seatunnel-mssql/-starrocks/-iceberg`, dagster `seatunnel_manifest.py`) | image ENTRYPOINT `/opt/entrypoint.sh driver\|executor`, `sparkVersion: 3.3.1`, mainClass `org.apache.seatunnel.core.starter.spark.SeaTunnelSpark`, starter `local:///opt/seatunnel/starter/seatunnel-spark-3-starter.jar`, `deps.jars` under `/opt/seatunnel/{lib,connectors,plugins}` | 185 |
| Zeta one-shot Job (`charts/seatunnel-zeta`, `render-landing-job.sh`) | `command: [/opt/seatunnel/bin/seatunnel.sh] args: [--config …, -m local]` | 0 |
| Zeta cluster Deployment (`charts/seatunnel-zeta-cluster`) | `bash -c "sed -i … /opt/seatunnel/bin/seatunnel-cluster.sh && exec …"`, ports 5801/8080, PVC at `/opt/seatunnel/checkpoint_snapshot` | 0 |

dataops ADR-0003 makes Zeta the target engine; Spark mode is retained as fixture/fallback. K8s `command:` bypasses the image
ENTRYPOINT in Zeta mode. dataops appends `-Xms1800m/-Xmx1800m` to `config/jvm_options` and `config/jvm_client_options`
(sized against a 2560Mi pod limit) — preserved verbatim. SeaTunnel 2.3.x only supports Spark 2.4/3.3 (upstream #9855), so Spark
stays at 3.3.1.

## What was measured

Trivy (vuln scanner, 2026-09-01):

| Image | CRITICAL / HIGH (all) | fixable | OS layer | jar layer |
|-------|----------------------|---------|----------|-----------|
| incumbent `localdev/seatunnel-spark:2.3.13` | 83 / 543 | 71 / 488 | 29 / 227 | 54 / 316 (40 of these in the unused Flink/Spark-2 starter jars) |
| base only `apache/spark:3.3.1` | 37 / 279 | 27 / 241 | 27 / 210 | 10 / 69 |
| base only `ubi9/ubi-minimal:9.6` | 0 / 26 | 0 / 20 | 0 / 26 | – |
| catalog `spark-ubi9:latest` (reference) | 4 / 101 | 3 / 89 | – | – |
| **new `seatunnel-spark-ubi9`** | _pending_ | _pending_ | _pending_ | _pending_ |

Trivy flags the incumbent OS as no longer supported. The jar-layer findings come from SeaTunnel 2.3.13 / Spark 3.3.1 and
carry over to any rebuild — they are a SeaTunnel/Spark version matter, not a base-image matter. The local pre-push
`trivy-scan.sh` gate (fixable CRITICAL/HIGH incl. jars) is already tripped by existing catalog images (`spark-ubi9`), so this
image does not introduce a new class of gate failure.

Spike matrix (UBI9-minimal 9.6 + SeaTunnel 2.3.13 + Spark 3.3.1 + the 7 `connectors.txt` jars, run as UID 185):

| Test | Zulu 11.0.32.1 | Red Hat OpenJDK 17.0.20.1 |
|------|----------------|---------------------------|
| Zeta local, FakeSource→Console template | pass (32/32 rows, FINISHED) | pass |
| Zeta cluster (server + client over 5801) | pass | pass |
| Spark local[2], direct `spark-submit` of `SeaTunnelSpark` | pass | pass |
| Spark local via `start-seatunnel-spark-3-connector-v2.sh` | pass | pass |
| JDBC load mssql-jdbc / mysql-connector-j (connection-refused = driver loaded) | pass / pass | pass / pass |
| JPMS symptoms | JDK 11 "illegal reflective access" warnings (same as incumbent) | Hazelcast "modular environment" performance advisory only; silenced by its 6 `--add-opens` flags |

JDK lifecycle (free, patched builds on UBI9-minimal):

| Runtime | Current | Free patches until |
|---------|---------|--------------------|
| UBI `java-11-openjdk-headless` | 11.0.25 (Oct 2024) — **frozen** | ended 2024-10-31 (ELS is paid) |
| UBI `java-17-openjdk-headless` | 17.0.20.1 | 2027-12-31 |
| UBI `java-21-openjdk-headless` | 21.0.12.1 | 2029-12-31 |
| Azul Zulu 11 CA | 11.0.32.1 | Jan 2032 |
| Azul Zulu 17 CA | 17.0.20.1 | Sept 2029 |

## Options

| Option | Fidelity | Security | Support horizon | Policy fit | Verdict |
|--------|----------|----------|-----------------|------------|---------|
| A. keep dataops-built / non-UBI special case | exact | EOL OS + 2022 JDK, no SBOM/provenance | none | fails `policy/base_image.rego` | reject |
| **B. UBI9-minimal + Zulu 11 (self-contained)** | same Java major, same JPMS semantics | UBI OS layer + patched JDK | 2032 | passes | **chosen** |
| C. UBI9-minimal + Red Hat OpenJDK 17 | Java major change; Zeta path unofficial | same OS; Red Hat-only supply chain | 2027 | passes | upgrade path (`ZULU_MAJOR=17` or swap to UBI OpenJDK later) |
| D. chain `FROM ghcr.io/nq-rdl/zulu17-jre-headless-ubi9` | as C, plus UID 1001 base | as C | 2029 | passes, needs bake/repin bootstrap | reject for now |

Devil's-advocate points considered: the jar-layer CVEs dominate and survive the rebuild (true — but the OS/JDK layer is the part
that is currently *unpatchable*, and only catalog builds get SBOM + provenance attestations); Java 17 aligns with the catalog and
upstream direction (true — but 2.3.13's Zeta engine carries no `--add-opens`, so untested production paths — Hadoop UGI, S3/Garage,
Iceberg REST, StarRocks sink, Kerberos — could hit `InaccessibleObjectException` only in production; Java 11 keeps warn-and-permit).

## Residual risks / required consumer validation

1. Local spikes did not exercise S3/Garage, real MSSQL/StarRocks/Iceberg REST, the spark-operator executor path, or Kerberos —
   dataops must run `smoke.sh` blocks against the published digest before switching `up.sh`.
2. The Azul yum repo (`cdn.azul.com`, `repos.azulsystems.com`) is a build-time third-party dependency (already accepted for the
   catalog's zulu images); the repo rpm is sha256-pinned and GPG-keyed.
3. `seatunnel-cluster.sh` logs to `$SEATUNNEL_HOME/logs/…` (not stdout) and does not forward SIGTERM to the JVM — identical to the
   incumbent; noted for K8s probes/termination.
4. Java 17 upgrade needs the Hazelcast `--add-opens` set in `config/jvm_*_options` for the Zeta engine (Spark injects its own).
5. Spark 3.3.1 release GPG key expired 2026-09-01 → artifacts are SHA-512-pinned instead of GPG-verified.

## Follow-ups

- dataops cut-over: replace the `up.sh` `docker build` + `k3d image import` with a pull of the published digest; update
  `pins.tf`/`VERSIONS.md` (`seatunnel_image`, `seatunnel_spark_base_image`); revisit the Zeta Job's `runAsUser: 0`
  workaround (UID 185 now has a passwd entry).
- Retire jar CVEs by bumping SeaTunnel/Spark when upstream supports it (SeaTunnel PR #11545 raises the Java floor to 11/17).
- Optional: `zulu11-jre-headless-ubi9` catalog image; arm64 platform.
