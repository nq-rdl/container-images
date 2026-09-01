# seatunnel-spark-ubi9

Apache SeaTunnel 2.3.13 — Zeta engine and Spark 3.3.1 engine — with the
StarRocks / JDBC / Iceberg connector set, on Red Hat UBI9-minimal with an Azul
Zulu 11 JRE.

This is the prebuilt, digest-pinnable drop-in for the image that
[nq-rdl/dataops](https://github.com/nq-rdl/dataops) currently builds locally as
`localdev/seatunnel-spark:2.3.13` (`local-dev/seatunnel/Dockerfile`, `FROM
apache/spark:3.3.1`). See issue #69 in this repo and dataops#139 Phase B: the
consumer should pull this image instead of building one.

Blueprint: dataops `local-dev/seatunnel/Dockerfile` + Spark 3.3.1
`kubernetes/dockerfiles/spark/Dockerfile`, adapted for UBI9-minimal using this
catalog's `spark-ubi9` and `zulu17-jre-headless-ubi9` patterns.

## Pull

```bash
podman pull ghcr.io/nq-rdl/seatunnel-spark-ubi9:2.3.13
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `2.3.13` | Specific SeaTunnel version, latest UBI9 patch |
| `2.3` | Latest patch of SeaTunnel 2.3.x |
| `latest` | Latest SeaTunnel version, latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.8` |
| Java | Azul Zulu 11.0.32.1 JRE headless (`zulu11-jre-headless`, Azul yum repo) |
| Spark | Apache Spark 3.3.1 (`spark-3.3.1-bin-hadoop3`, jars/bin/sbin only) |
| SeaTunnel | Apache SeaTunnel 2.3.13 (`apache-seatunnel-2.3.13-bin`) |
| User | 185, named `spark` (non-root, Spark convention, has an `/etc/passwd` entry) |
| `SPARK_HOME` | `/opt/spark` |
| `SEATUNNEL_HOME` | `/opt/seatunnel` (symlink to `/opt/apache-seatunnel-2.3.13`) |
| `JAVA_HOME` | `/usr/lib/jvm/zulu11` |
| Init | `tini` v0.19.0 at `/usr/bin/tini` |
| Platforms | linux/amd64 |
| Catalog support | Stable through 2027-12-31; this is a forced review date for the legacy SeaTunnel 2.3 / Spark 3.3 stack, not the UBI or Zulu EOL |

## Contents / bill of materials

Every artifact is downloaded at build time and checksum-verified before use.
Full SHA-512 values for the jars are in [`connectors.txt`](connectors.txt);
the tarball and tini pins are `ARG`s at the top of the
[`Containerfile`](Containerfile). CI additionally attaches a CycloneDX SBOM and
build provenance to every published image (see *Verify attestations*).

| Artifact | Version | Checksum (prefix) | Lands in |
|----------|---------|-------------------|----------|
| `spark-3.3.1-bin-hadoop3.tgz` | 3.3.1 | sha512 `769db39a560a` | `/opt/spark/{jars,bin,sbin,RELEASE}`, `/opt/decom.sh` |
| `apache-seatunnel-2.3.13-bin.tar.gz` | 2.3.13 | sha512 `499fc1926a7a` | `/opt/apache-seatunnel-2.3.13` (= `/opt/seatunnel`) |
| `connector-starrocks` | 2.3.13 | sha512 `64062619515b` | `/opt/seatunnel/connectors/` |
| `connector-jdbc` | 2.3.13 | sha512 `5ab7c89f2a7b` | `/opt/seatunnel/connectors/` |
| `connector-iceberg` | 2.3.13 | sha512 `5d283154d969` | `/opt/seatunnel/connectors/` |
| `iceberg-spark-runtime-3.3_2.12` | 1.8.1 | sha512 `3ef9ed6b1297` | `/opt/seatunnel/plugins/` |
| `iceberg-aws-bundle` | 1.8.1 | sha512 `ba928446b65c` | `/opt/seatunnel/plugins/` |
| `mysql-connector-j` | 8.4.0 | sha512 `02f4b5a07b9d` | `/opt/seatunnel/plugins/` |
| `mssql-jdbc` | 12.8.1.jre11 | sha512 `b5bca144f515` | `/opt/seatunnel/plugins/` |
| `tini` | v0.19.0 | sha256 `93dcc18adc78` (amd64) / `07952557df20` (arm64) | `/usr/bin/tini` |
| `zulu-repo` RPM | 1.0.0-1 | sha256 `2724b8be277e` | Azul yum repo definition |
| `zulu11-jre-headless` | 11.0.32.1 | RPM, GPG-signed (Azul key) | `/usr/lib/jvm/zulu11` |

The SeaTunnel tarball's bundled `connector-fake`, `connector-console` and
`connector-cdc-base` are kept; its `seatunnel-starter.jar` (Zeta) and
`seatunnel-spark-3-starter.jar` (Spark) are kept. Its Flink 1.3/1.5/2.0 and
Spark 2 starters, the matching `start-seatunnel-*-connector-v2.sh` launchers,
all `*.cmd` Windows scripts and `mvnw.cmd` are removed (unused by any consumer;
about 160 MB and 40 CRITICAL/HIGH Trivy findings fewer).

## Image layout contract

Paths that dataops manifests and charts rely on. Treat these as stable.

| Path | Purpose |
|------|---------|
| `/opt/entrypoint.sh` | Image `ENTRYPOINT`; `driver` / `executor` modes for spark-operator, anything else is exec'd under tini |
| `/opt/seatunnel/bin/seatunnel.sh` | Zeta client (`-m local` runs the engine in-process) |
| `/opt/seatunnel/bin/seatunnel-cluster.sh` | Zeta server; logs to `/opt/seatunnel/logs/seatunnel-engine-server.log` |
| `/opt/seatunnel/bin/start-seatunnel-spark-3-connector-v2.sh` | Spark 3 launcher (wraps `spark-submit`) |
| `/opt/seatunnel/starter/seatunnel-spark-3-starter.jar` | `mainApplicationFile` for SparkApplication |
| `/opt/seatunnel/lib/{seatunnel-hadoop-aws.jar,seatunnel-hadoop3-3.1.4-uber.jar,seatunnel-transforms-v2.jar}` | `deps.jars` for SparkApplication |
| `/opt/seatunnel/connectors/*.jar`, `/opt/seatunnel/plugins/*.jar` | Connector / plugin jars from `connectors.txt` |
| `/opt/seatunnel/config/{seatunnel.yaml,hazelcast.yaml,hazelcast-client.yaml}` | Zeta config; charts mount replacements via `subPath` |
| `/opt/seatunnel/config/{jvm_options,jvm_client_options}` | Carry `-Xms1800m -Xmx1800m` (override with `-DJvmOption=-Xmx...`) |
| `/opt/seatunnel/logs/` | Exists, owned by uid 185 |
| `/opt/seatunnel/checkpoint_snapshot` | Conventional PVC mount point for Zeta cluster checkpoints |
| `/opt/spark/work-dir` | `WORKDIR`, group-writable |
| `/opt/decom.sh` | Spark executor decommission hook |

## Usage

### Zeta one-shot job (`-m local`)

```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsUser: 185, runAsGroup: 185, fsGroup: 185 }
      containers:
        - name: seatunnel
          image: ghcr.io/nq-rdl/seatunnel-spark-ubi9:2.3.13@sha256:<digest>
          command: ["/opt/seatunnel/bin/seatunnel.sh"]
          args: ["--config", "/opt/seatunnel/job/job.conf", "-m", "local"]
          resources: { limits: { memory: 2560Mi } }
          volumeMounts:
            - { name: job, mountPath: /opt/seatunnel/job }
      volumes:
        - name: job
          configMap: { name: seatunnel-job }
```

A Kubernetes `command:` replaces the image `ENTRYPOINT`, so tini is not in the
path here (same as the incumbent). The baked `-Xmx1800m` is sized for a
2560Mi limit; keep them in lockstep.

### Zeta cluster (Deployment)

Run `/opt/seatunnel/bin/seatunnel-cluster.sh` (ports 5801 Hazelcast, 8080
REST). The server writes `${SEATUNNEL_HOME}/logs/seatunnel-engine-server.log`,
so `/opt/seatunnel/logs` must stay writable by the runtime UID (it is owned by
185 in the image; mount an `emptyDir` there if you run under another UID).
Mount `seatunnel.yaml` / `hazelcast.yaml` via `subPath` and the checkpoint
PVC at `/opt/seatunnel/checkpoint_snapshot`, as the dataops charts do.

### Spark engine (spark-operator `SparkApplication`)

```yaml
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
spec:
  type: Java
  mode: cluster
  sparkVersion: "3.3.1"
  image: ghcr.io/nq-rdl/seatunnel-spark-ubi9:2.3.13@sha256:<digest>
  mainClass: org.apache.seatunnel.core.starter.spark.SeaTunnelSpark
  mainApplicationFile: local:///opt/seatunnel/starter/seatunnel-spark-3-starter.jar
  arguments: ["--config", "/opt/seatunnel/job/job.conf", "--master", "k8s", "--deploy-mode", "cluster"]
  deps:
    jars:
      - local:///opt/seatunnel/lib/seatunnel-hadoop-aws.jar
      - local:///opt/seatunnel/lib/seatunnel-hadoop3-3.1.4-uber.jar
      - local:///opt/seatunnel/lib/seatunnel-transforms-v2.jar
      - local:///opt/seatunnel/connectors/connector-fake-2.3.13.jar
      - local:///opt/seatunnel/connectors/connector-jdbc-2.3.13.jar
      - local:///opt/seatunnel/connectors/connector-starrocks-2.3.13.jar
      - local:///opt/seatunnel/plugins/mysql-connector-j-8.4.0.jar
      - local:///opt/seatunnel/plugins/mssql-jdbc-12.8.1.jre11.jar
  driver:
    env: [{ name: SEATUNNEL_HOME, value: /opt/seatunnel }]
    securityContext: { runAsUser: 185 }
  executor:
    instances: 1
    securityContext: { runAsUser: 185 }
```

The image `ENTRYPOINT` handles `driver` / `executor` exactly like
`apache/spark:3.3.1` (same `KubernetesExecutorBackend` argument list).

## Differences from the dataops-built image

| Area | `localdev/seatunnel-spark:2.3.13` (dataops) | `seatunnel-spark-ubi9` |
|------|----------------------------------------------|------------------------|
| OS | Debian 11.4 bullseye (from `apache/spark:3.3.1`, built 2022-10; Debian 11 LTS ended 2026-08-31) | UBI9-minimal 9.8 |
| Java | OpenJDK 11.0.16+8 tarball at `/usr/local/openjdk-11` (invisible to scanners; 16 missed CPUs) | Azul Zulu 11.0.32.1 JRE headless RPM at `/usr/lib/jvm/zulu11` |
| User | `USER 185`, no passwd entry (Zeta Job runs as root to work around Hadoop UGI) | named `spark` uid/gid 185 with passwd entry |
| Spark payload | full `apache/spark:3.3.1` (examples, python, R, data) | jars/bin/sbin/RELEASE + `decom.sh` only |
| SeaTunnel payload | full tarball | Flink 1.3/1.5/2.0 + Spark 2 starters/launchers, `*.cmd`, `mvnw.cmd` removed |
| Entrypoint pass-through | `exec "$@"` | `exec /usr/bin/tini -s -- "$@"` (SIGTERM reaches the JVM under `podman run`) |
| Verification | SHA-512 tarball + jars | SHA-512 tarballs + jars, sha256 tini + zulu-repo, GPG-signed JRE RPM |
| `EXTRA_CA_CERTS_B64` build arg | present (corporate-proxy CA for local builds) | not present — CI builds are proxy-free, and the point of Phase B is that dataops pulls instead of builds |
| Heap in `jvm_options` / `jvm_client_options` | `-Xms1800m -Xmx1800m` | identical (`SEATUNNEL_HEAP` build arg) |

## Java version

**Why Zulu 11.** SeaTunnel 2.3.13 officially supports Java 8 or 11 (it is
compiled for 8 and bundles Hazelcast 5.1 with no JPMS flags in its scripts).
Red Hat's UBI9 `java-11-openjdk-headless` is frozen at 11.0.25 (OpenJDK 11 full
support ended 2024-10-31; extended support is paid-only), whereas Azul Zulu 11
community builds are free and patched quarterly until January 2032. The Azul
yum repo is the same mechanism this catalog already uses for
`zulu17-jre-headless-ubi9`, and the RPM install makes the JDK visible to Trivy.

**Java 17 is validated.** The final Containerfile build with Zulu 17.0.20.1
passed Zeta local, Zeta cluster with the dataops classpath patch, Spark local
through both direct `SeaTunnelSpark` and the upstream wrapper, and verified
that the MSSQL and MySQL JDBC drivers load. Spark 3.3.1 injects the required
`--add-opens` for its driver and executors. To build it:

```bash
podman build -f images/seatunnel-spark-ubi9/Containerfile \
  --build-arg ZULU_MAJOR=17 --build-arg ZULU_VERSION=17.0.20.1 \
  -t seatunnel-spark-ubi9:2.3.13-zulu17 images/seatunnel-spark-ubi9
```

Both Java 11 and 17 print Hazelcast's "modular environment" performance
advisory. It is non-fatal; add the following flags for full internal-API access:

```text
--add-modules java.se
--add-exports java.base/jdk.internal.ref=ALL-UNNAMED
--add-opens java.base/java.lang=ALL-UNNAMED
--add-opens java.base/sun.nio.ch=ALL-UNNAMED
--add-opens java.management/sun.management=ALL-UNNAMED
--add-opens jdk.management/com.sun.management.internal=ALL-UNNAMED
```

Zulu 11 additionally prints the JDK 11 "illegal reflective access" warning
that the incumbent prints; Zulu 17 does not.

## Security

- **OS layer.** Trivy on the incumbent reports 29 CRITICAL / 227 HIGH in
  Debian OS packages and warns *"This OS version is no longer supported"*.
  The final UBI9-minimal 9.8 image reports **0 CRITICAL / 9 HIGH** OS-package
  findings, none fixable in the enabled repositories. The catalog's base-repin
  flow keeps that layer current.
- **Java.** The JDK is now an RPM, so it is visible to Trivy and to
  `rpm -qa`; the incumbent's tarball JDK was not scanned at all.
- **Jars.** The final image reports **54 CRITICAL / 276 HIGH** jar findings;
  Trivy marks 53 / 274 respectively as having an upstream fixed version.
  They are inherited from the SeaTunnel 2.3.13 / Spark 3.3.1 / Hadoop 3.1.4
  sets. Pruning the unused Flink/Spark-2 starters removes about 40 additional
  CRITICAL/HIGH findings. The local pre-push `trivy-scan.sh` hook therefore
  flags this image, as it does existing legacy-stack catalog images; retirement
  requires a SeaTunnel/Spark version bump rather than an OS-layer workaround.
- The image runs as non-root uid 185 with no setuid helpers (`pam_wheel`
  restricts `su`).

## Verify attestations

```bash
gh attestation verify oci://ghcr.io/nq-rdl/seatunnel-spark-ubi9:2.3.13 \
  --repo nq-rdl/container-images
```

CI publishes build provenance and a CycloneDX SBOM for every image; that SBOM
is the authoritative bill of materials for a given digest.

## Migration review

The full base-swap analysis (incumbent inventory, consumer usage modes, JDK
lifecycle comparison, Java 11 vs 17 spike results, Trivy before/after) is in
[`docs/seatunnel-spark-ubi9-migration-review.md`](../../docs/seatunnel-spark-ubi9-migration-review.md).

## Consumer follow-ups (dataops)

Tracked in [dataops#362](https://github.com/nq-rdl/dataops/issues/362).

- Replace the `up.sh` `docker build` + `k3d image import` of
  `localdev/seatunnel-spark:2.3.13` with a digest-pinned pull of
  `ghcr.io/nq-rdl/seatunnel-spark-ubi9:2.3.13@sha256:...`.
- Update `local-dev/tofu/pins.tf` / `VERSIONS.md` `seatunnel_image` to the new
  reference; keep `connectors.txt` in dataops and in this repo in lockstep
  (or drop the dataops copy once nothing there builds the image).
- The Zeta Job's `runAsUser: 0` workaround can be revisited: uid 185 now has
  an `/etc/passwd` entry, so Hadoop UGI login succeeds as `spark`.
- `SparkApplication.spec.sparkVersion` stays `3.3.1`; `mainClass`,
  `mainApplicationFile` and `deps.jars` paths are unchanged.
