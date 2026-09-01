# seatunnel-spark → UBI9 migration review

Status: **validated** (2026-09-01). The final UBI9-minimal 9.8 Containerfile, both Zulu build paths, runtime matrix,
file-tree parity and after-build Trivy numbers have been checked.
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
- **Proven empirically on the final UBI9-minimal 9.8 image** with both Zulu 11.0.32.1 and Zulu 17.0.20.1:
  Zeta local (`seatunnel.sh -m local`), Zeta cluster with the dataops classpath patch, Spark 3.3.1 local
  (direct `SeaTunnelSpark` and the upstream wrapper), and JDBC driver load for mssql-jdbc 12.8.1.jre11 / mysql-connector-j 8.4.0.
- **Zulu catalog images: the pattern yes, chaining no.** `zulu17/21-*-ubi9` force Java 17/21 and the chained-image bake/repin
  machinery; the Azul-repo recipe is copied instead (a future `zulu11-jre-headless-ubi9` image is possible).
- **Catalog support EOL: 2027-12-31.** This is a forced review date for the legacy SeaTunnel 2.3 / Spark 3.3 stack, not the
  UBI9 or Zulu 11 support horizon; retaining the image beyond it requires an explicit version/security review.

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
| **new `seatunnel-spark-ubi9`** | **54 / 285** | **53 / 274** | **0 / 9** | **54 / 276** |

Trivy flags the incumbent OS as no longer supported. The new image has no CRITICAL OS-package finding and none of its nine
HIGH OS-package findings has a fix in the enabled repositories. The jar findings come from SeaTunnel 2.3.13, Spark 3.3.1
and Hadoop 3.1.4 and carry over to any rebuild. They are a version matter, not a base-image matter. The local pre-push
`trivy-scan.sh` gate flags their fixed-version metadata, as it already does for legacy-stack catalog images.

Final-image matrix (UBI9-minimal 9.8 + SeaTunnel 2.3.13 + Spark 3.3.1 + the 7 `connectors.txt` jars, run as UID 185):

| Test | Zulu 11.0.32.1 | Zulu 17.0.20.1 |
|------|----------------|----------------|
| Zeta local, FakeSource→Console template | pass (32/32 rows, FINISHED) | pass (32/32 rows, FINISHED) |
| Zeta cluster with dataops classpath patch | pass | pass |
| Spark `local[2]`, direct `SeaTunnelSpark` with Fake/Console `--jars` | pass | pass |
| Spark local via `start-seatunnel-spark-3-connector-v2.sh` | pass | pass |
| JDBC class load, mssql-jdbc / mysql-connector-j | pass / pass | pass / pass |
| JPMS symptoms | Hazelcast modular-environment advisory + JDK 11 illegal-access warning | Hazelcast modular-environment advisory only |

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

1. Local tests did not exercise S3/Garage, real MSSQL/StarRocks/Iceberg REST, the spark-operator executor path, or Kerberos —
   dataops must run `smoke.sh` blocks against the published digest before switching `up.sh`.
2. The Azul yum repo (`cdn.azul.com`, `repos.azulsystems.com`) is a build-time third-party dependency (already accepted for the
   catalog's zulu images); the repo rpm is sha256-pinned and GPG-keyed.
3. `seatunnel-cluster.sh` logs to `$SEATUNNEL_HOME/logs/…` (not stdout) and does not forward SIGTERM to the JVM — identical to the
   incumbent; noted for K8s probes/termination.
4. Before making Java 17 the default, add Hazelcast's six JPMS flags for full internal-API access; the tested path is
   functional without them but prints its performance advisory.
5. Spark 3.3.1 release GPG key expired 2026-09-01 → artifacts are SHA-512-pinned instead of GPG-verified.

## Follow-ups

- dataops cut-over is tracked in [dataops#362](https://github.com/nq-rdl/dataops/issues/362): replace the `up.sh`
  `docker build` + `k3d image import` with a pull of the published digest; update `pins.tf`/`VERSIONS.md`
  (`seatunnel_image`, `seatunnel_spark_base_image`); revisit the Zeta Job's `runAsUser: 0` workaround.
- Retire jar CVEs by bumping SeaTunnel/Spark when upstream supports it (SeaTunnel PR #11545 raises the Java floor to 11/17).
- Optional: `zulu11-jre-headless-ubi9` catalog image; arm64 platform.
