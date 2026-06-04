# StarRocks UBI9 Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four StarRocks images (`starrocks-fe-ubi9`, `starrocks-be-ubi9`, `starrocks-cn-ubi9`, `starrocks-allin1-ubi9`), each built in two version lines (4.1.1 → `latest`, and 3.3.22), by repackaging `starrocks/artifacts-centos7` onto a pinned `ubi9/ubi:9.8` base. Closes #29.

**Architecture:** Each image directory has a multi-stage `Containerfile` that declares two literal, digest-pinned artifact stages (`artifacts-4.1.1`, `artifacts-3.3.22`) and selects one with a stage-ref `FROM artifacts-${STARROCKS_VERSION}` (the repo's `build_matrix.arg` mechanism drives the build-arg). The final stage is `ubi9/ubi:9.8`, installs runtime deps with `dnf`, and copies the StarRocks binaries + vendored Operator scripts. No server-starting default command (the Operator supplies it); a tiny `smoke.sh` provides the smoke-test gate.

**Tech Stack:** Containerfile (BuildKit `dockerfile:1.7`), UBI9 `dnf`, StarRocks `artifacts-centos7` images, pixi-managed tooling (hadolint, conftest/OPA, shellcheck, trivy), `build.yml` GitHub Actions matrix, changie.

---

## File Structure

```
images/starrocks-fe-ubi9/
  Containerfile         # FE: dual artifact stages → ubi9/ubi; copy /release/fe_artifacts
  image.yaml            # metadata + build_matrix (4.1.1, 3.3.22)
  README.md             # image docs
  smoke-cmd             # "bash smoke.sh"
  smoke.sh              # JVM + artifact-presence gate (exit 0)
  fe_entrypoint.sh      # vendored upstream (ref 4.1.1)
  fe_prestop.sh         # vendored upstream
images/starrocks-be-ubi9/
  Containerfile         # BE: copy /release/be_artifacts; cn→be symlink; be/storage dir
  image.yaml
  README.md
  smoke-cmd             # "bash smoke.sh"
  smoke.sh              # native starrocks_be linkage/glibc gate + JVM
  be_entrypoint.sh  be_prestop.sh  cn_entrypoint.sh  cn_prestop.sh  upload_coredump.sh   # vendored
images/starrocks-cn-ubi9/
  Containerfile         # CN: BE-derived (compute-only); copy /release/be_artifacts
  image.yaml
  README.md
  smoke-cmd  smoke.sh
  cn_entrypoint.sh  cn_prestop.sh  upload_coredump.sh   # vendored
images/starrocks-allin1-ubi9/
  Containerfile         # FE+BE+supervisor+nginx feproxy single-node demo
  image.yaml
  README.md
  smoke-cmd  smoke.sh
  entrypoint.sh  health_check.sh  be.conf  fe.conf  banner.txt   # vendored
  services/director/run.sh  services/feproxy/feproxy.conf.template  services/supervisor/supervisord.conf   # vendored
.changes/unreleased/Added-<timestamp>.yaml   # changie fragment
```

Pinned references (verified 2026-06-04, all amd64-covering indexes):

| Reference | Index digest |
|-----------|--------------|
| `registry.access.redhat.com/ubi9/ubi:9.8` | `sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08` |
| `starrocks/artifacts-centos7:4.1.1` | `sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a` |
| `starrocks/artifacts-centos7:3.3.22` | `sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3` |

---

## Task 0: Discovery — resolve UBI9-specific values

Resolves four unknowns the later tasks reference: (a) `JAVA_HOME` path on UBI9, (b) the el9 MySQL release RPM URL, (c) the `starrocks_be` version flag + artifact layout, (d) shellcheck scope over `images/`. Branch `feat/starrocks-ubi9-images` already exists with the design spec committed.

**Files:** none created; this task records values used verbatim below.

- [ ] **Step 1: Confirm shellcheck does not gate vendored `images/**/*.sh`**

Run: `sed -n '1,80p' .pre-commit-config.yaml`
Expected: confirm the `shellcheck` hook's `files:`/`exclude:` scope. The pixi `lint-shell` task only globs `scripts tests`. If the pre-commit hook globs `images/`, add `exclude: ^images/.*\.sh$` in Task 6 (vendored upstream scripts are not ours to lint). Record the finding.

- [ ] **Step 2: Probe UBI9 for the real `JAVA_HOME` and package availability**

Run:
```bash
podman run --rm registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08 \
  bash -c 'dnf install -y --nodocs java-11-openjdk-devel >/dev/null 2>&1; \
           echo "java bin: $(readlink -f /usr/bin/java)"; \
           ls -d /usr/lib/jvm/java-11* /usr/lib/jvm/java-11 2>/dev/null; \
           for p in tzdata openssl curl vim-minimal ca-certificates fontconfig gzip tar less hostname procps-ng lsof nmap-ncat nginx python3-pip; do \
             dnf -q list --available "$p" >/dev/null 2>&1 && echo "AVAIL $p" || echo "MISSING $p"; done'
```
Expected: prints the resolved `java` path. Set `JAVA_HOME` to the directory whose `bin/java` matches (typically `/usr/lib/jvm/java-11-openjdk` with a `/usr/lib/jvm/java-11` symlink). **Record the confirmed `JAVA_HOME`** — if `/usr/lib/jvm/java-11` does not exist, use the concrete `/usr/lib/jvm/java-11-openjdk` path in every Containerfile below. Confirm all listed packages are AVAIL (note any MISSING for substitution, e.g. `vim-minimal`→drop, `nmap-ncat` provides `nc`).

- [ ] **Step 3: Confirm the current el9 MySQL release RPM URL**

Run:
```bash
for n in 1 2 3 4 5 6 7; do url="https://repo.mysql.com/mysql80-community-release-el9-${n}.noarch.rpm"; \
  code=$(curl -fsS -o /dev/null -w '%{http_code}' -I "$url" || echo 000); echo "$code  $url"; done
```
Expected: the highest `-N` returning `200` is the current release RPM. **Record that exact URL** for the `rpm -ivh` line in FE/BE/CN/allin1 Containerfiles (replace the `-1` placeholder used below). If none return 200, fall back to UBI's own client: replace the three MySQL lines with `dnf install -y --nodocs mysql` and record that substitution.

- [ ] **Step 4: Inspect the artifact image layout + `starrocks_be` version flag**

Run:
```bash
cid=$(podman create starrocks/artifacts-centos7:4.1.1@sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a)
podman export "$cid" | tar -tv 2>/dev/null | grep -E 'release/(fe|be)_artifacts/(fe|be)/(bin|lib)/(start_|starrocks_be|starrocks-fe)' | head -40
podman rm "$cid" >/dev/null
```
Expected: confirms `/release/fe_artifacts/fe/{bin/start_fe.sh,lib/starrocks-fe.jar}` and `/release/be_artifacts/be/{bin/start_be.sh,lib/starrocks_be}`. These map under `/opt/starrocks/` after COPY. The `starrocks_be --version` behavior is verified during the BE build (Task 2, Step 4); the BE `smoke.sh` gates on dynamic-link resolution (deterministic) rather than the flag.

- [ ] **Step 5: Record resolved values inline**

No commit. Carry forward: `JAVA_HOME=<resolved>`, `MYSQL_EL9_RPM=<resolved url>`, artifact paths confirmed. The Containerfiles below use `JAVA_HOME=/usr/lib/jvm/java-11` and `mysql80-community-release-el9-1.noarch.rpm` as defaults — **substitute the resolved values** if Steps 2–3 differ.

---

## Task 1: FE image (`starrocks-fe-ubi9`)

**Files:**
- Create: `images/starrocks-fe-ubi9/Containerfile`
- Create: `images/starrocks-fe-ubi9/image.yaml`
- Create: `images/starrocks-fe-ubi9/README.md`
- Create: `images/starrocks-fe-ubi9/smoke-cmd`
- Create: `images/starrocks-fe-ubi9/smoke.sh`
- Create (vendored): `images/starrocks-fe-ubi9/fe_entrypoint.sh`, `images/starrocks-fe-ubi9/fe_prestop.sh`

- [ ] **Step 1: Vendor the upstream FE scripts (pinned ref 4.1.1)**

```bash
mkdir -p images/starrocks-fe-ubi9
for f in fe_entrypoint.sh fe_prestop.sh; do
  gh api "repos/StarRocks/starrocks/contents/docker/dockerfiles/fe/${f}?ref=4.1.1" \
    -H "Accept: application/vnd.github.raw" > "images/starrocks-fe-ubi9/${f}"
done
chmod +x images/starrocks-fe-ubi9/*.sh
```
Expected: two non-empty scripts. Do not edit them (upstream Operator glue).

- [ ] **Step 2: Write `images/starrocks-fe-ubi9/Containerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
#
# StarRocks FE (Frontend) on UBI9
# Blueprint: StarRocks/starrocks docker/dockerfiles/fe/fe-ubi.Dockerfile (ref 4.1.1)
# Changes: ubi8/ubi:8.7 -> ubi9/ubi:9.8 (index-digest pinned); yum -> dnf + cache
#          cleanup; MySQL release RPM el8 -> el9; dual digest-pinned artifact stages
#          selected by ARG STARROCKS_VERSION for the build_matrix.
#
FROM starrocks/artifacts-centos7:4.1.1@sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a AS artifacts-4.1.1
FROM starrocks/artifacts-centos7:3.3.22@sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3 AS artifacts-3.3.22

ARG STARROCKS_VERSION=4.1.1
FROM artifacts-${STARROCKS_VERSION} AS artifacts

FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08

ARG STARROCKS_VERSION
ARG STARROCKS_ROOT=/opt/starrocks
ARG STARROCKS_USER=starrocks
ARG STARROCKS_GROUP=starrocks

LABEL org.opencontainers.image.title="starrocks-fe-ubi9"
LABEL org.opencontainers.image.description="StarRocks FE (Frontend) ${STARROCKS_VERSION} on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# hadolint ignore=DL3041
RUN dnf install -y --nodocs --setopt=install_weak_deps=0 \
        java-11-openjdk-devel \
        tzdata openssl curl vim-minimal ca-certificates fontconfig \
        gzip tar less hostname procps-ng lsof nmap-ncat \
    && rpm -ivh https://repo.mysql.com/mysql80-community-release-el9-1.noarch.rpm \
    && dnf install -y --nodocs --nogpgcheck mysql-community-client \
    && dnf remove -y mysql80-community-release \
    && dnf upgrade -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

ENV JAVA_HOME=/usr/lib/jvm/java-11

RUN touch /.dockerenv

WORKDIR ${STARROCKS_ROOT}

RUN groupadd --gid 1000 ${STARROCKS_GROUP} \
    && useradd --no-create-home --uid 1000 --gid 1000 --shell /usr/sbin/nologin ${STARROCKS_USER} \
    && chown -R ${STARROCKS_USER}:${STARROCKS_GROUP} ${STARROCKS_ROOT}

USER ${STARROCKS_USER}

COPY --from=artifacts --chown=${STARROCKS_USER}:${STARROCKS_GROUP} /release/fe_artifacts/ ${STARROCKS_ROOT}/
COPY --chown=${STARROCKS_USER}:${STARROCKS_GROUP} *.sh ${STARROCKS_ROOT}/

RUN mkdir -p ${STARROCKS_ROOT}/fe/meta

# No server-starting default command — the StarRocks Operator supplies it.
# Final USER is root to match upstream fe-ubi (RUN_AS_USER=root); the Operator
# overrides via securityContext.
USER root
```

- [ ] **Step 3: Write `images/starrocks-fe-ubi9/smoke.sh` and `smoke-cmd`**

`smoke.sh`:
```bash
#!/usr/bin/env bash
# Fast, deterministic smoke gate for the FE image (must exit 0).
set -euo pipefail
java -version
test -f /opt/starrocks/fe/lib/starrocks-fe.jar
test -x /opt/starrocks/fe/bin/start_fe.sh
echo "starrocks-fe-ubi9 smoke OK"
```
`smoke-cmd` (single line, no trailing newline issues):
```
bash smoke.sh
```
Then: `chmod +x images/starrocks-fe-ubi9/smoke.sh`

- [ ] **Step 4: Build the default (4.1.1) variant and verify it runs the smoke gate**

Run:
```bash
podman build -t localhost/smoke/starrocks-fe-ubi9:4.1.1 images/starrocks-fe-ubi9
podman run --rm -w /opt/starrocks localhost/smoke/starrocks-fe-ubi9:4.1.1 bash smoke.sh
```
Expected: build succeeds; run prints `openjdk version "11..."` and `starrocks-fe-ubi9 smoke OK` and exits 0. If `java -version` fails, fix `JAVA_HOME`/package name from Task 0 Step 2. If the MySQL RPM line fails, apply the Task 0 Step 3 URL or fallback.

- [ ] **Step 5: Write `images/starrocks-fe-ubi9/image.yaml`**

```yaml
name: starrocks-fe-ubi9
description: StarRocks FE (Frontend) on UBI9
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: registry.access.redhat.com
  repository: ubi9/ubi
  version: "9.8"
runtime:
  name: starrocks-fe
tags:
  - "4.1"
  - "4.1.1"
  - "3.3"
  - "3.3.22"
  - "latest"
build_matrix:
  arg: STARROCKS_VERSION
  versions:
    - version: "4.1.1"
      tags: ["4.1", "4.1.1", "latest"]
    - version: "3.3.22"
      tags: ["3.3", "3.3.22"]
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 6: Write `images/starrocks-fe-ubi9/README.md`**

```markdown
# starrocks-fe-ubi9

StarRocks FE (Frontend / coordinator) repackaged onto Red Hat UBI9, for deployment
via the [StarRocks Kubernetes Operator](https://github.com/StarRocks/starrocks-kubernetes-operator).

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/fe/fe-ubi.Dockerfile`, adapted from UBI8 to UBI9 and built by
repackaging `starrocks/artifacts-centos7`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/starrocks-fe-ubi9:4.1.1
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `4.1.1` / `4.1` | StarRocks 4.1.1, latest UBI9 patch |
| `3.3.22` / `3.3` | StarRocks 3.3.22, latest UBI9 patch |
| `latest` | Latest StarRocks (4.1 line), latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | StarRocks FE with OpenJDK 11 |
| Platforms | linux/amd64 |
| StarRocks Home | `/opt/starrocks` |
| Default command | none — supplied by the Operator (`fe_entrypoint.sh` is bundled) |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-fe-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
```

- [ ] **Step 7: Lint + policy-check the FE image**

Run:
```bash
pixi run -- hadolint --config .hadolint.yaml images/starrocks-fe-ubi9/Containerfile
pixi run -- conftest test --policy policy/ --parser dockerfile images/starrocks-fe-ubi9/Containerfile
pixi run -- conftest test --policy policy/image-meta/ --namespace image_meta images/starrocks-fe-ubi9/image.yaml
bash tests/test-base-images-pinned.sh
```
Expected: hadolint clean (≤ warning threshold); both conftest runs report `0 failures`; pin test prints `PASS` for the UBI base + both artifact lines and `stage ref, exempt` for `artifacts-${STARROCKS_VERSION}`, then `All external base images are digest-pinned`.

- [ ] **Step 8: Commit**

```bash
git add images/starrocks-fe-ubi9
git commit -m "feat(starrocks-fe-ubi9): StarRocks FE on UBI9 (4.1.1 + 3.3.22) (#29)"
```

---

## Task 2: BE image (`starrocks-be-ubi9`)

**Files:**
- Create: `images/starrocks-be-ubi9/{Containerfile,image.yaml,README.md,smoke-cmd,smoke.sh}`
- Create (vendored): `be_entrypoint.sh`, `be_prestop.sh`, `cn_entrypoint.sh`, `cn_prestop.sh`, `upload_coredump.sh`

- [ ] **Step 1: Vendor the upstream BE+CN scripts**

```bash
mkdir -p images/starrocks-be-ubi9
for f in be_entrypoint.sh be_prestop.sh cn_entrypoint.sh cn_prestop.sh upload_coredump.sh; do
  gh api "repos/StarRocks/starrocks/contents/docker/dockerfiles/be/${f}?ref=4.1.1" \
    -H "Accept: application/vnd.github.raw" > "images/starrocks-be-ubi9/${f}"
done
chmod +x images/starrocks-be-ubi9/*.sh
```
Expected: five non-empty scripts.

- [ ] **Step 2: Write `images/starrocks-be-ubi9/Containerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
#
# StarRocks BE (Backend) on UBI9
# Blueprint: StarRocks/starrocks docker/dockerfiles/be/be-ubi.Dockerfile (ref 4.1.1)
# Changes: ubi8/ubi:8.7 -> ubi9/ubi:9.8 (index-digest pinned); yum -> dnf + cache
#          cleanup; MySQL release RPM el8 -> el9; BE java-1.8.0 -> java-11 (Java 8
#          absent from UBI9 repos; current upstream BE uses JDK 11); dual digest-
#          pinned artifact stages selected by ARG STARROCKS_VERSION.
#
FROM starrocks/artifacts-centos7:4.1.1@sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a AS artifacts-4.1.1
FROM starrocks/artifacts-centos7:3.3.22@sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3 AS artifacts-3.3.22

ARG STARROCKS_VERSION=4.1.1
FROM artifacts-${STARROCKS_VERSION} AS artifacts
# Drop the BE debug-info to keep the runtime image lean (matches upstream be-ubi).
RUN rm -f /release/be_artifacts/be/lib/starrocks_be.debuginfo

FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08

ARG STARROCKS_VERSION
ARG STARROCKS_ROOT=/opt/starrocks
ARG STARROCKS_USER=starrocks
ARG STARROCKS_GROUP=starrocks

LABEL org.opencontainers.image.title="starrocks-be-ubi9"
LABEL org.opencontainers.image.description="StarRocks BE (Backend) ${STARROCKS_VERSION} on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# hadolint ignore=DL3041
RUN dnf install -y --nodocs --setopt=install_weak_deps=0 \
        java-11-openjdk-devel \
        tzdata openssl curl vim-minimal ca-certificates fontconfig \
        gzip tar less hostname procps-ng lsof \
    && rpm -ivh https://repo.mysql.com/mysql80-community-release-el9-1.noarch.rpm \
    && dnf install -y --nodocs --nogpgcheck mysql-community-client \
    && dnf remove -y mysql80-community-release \
    && dnf upgrade -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

ENV JAVA_HOME=/usr/lib/jvm/java-11

RUN touch /.dockerenv

WORKDIR ${STARROCKS_ROOT}

RUN groupadd --gid 1000 ${STARROCKS_GROUP} \
    && useradd --no-create-home --uid 1000 --gid 1000 --shell /usr/sbin/nologin ${STARROCKS_USER} \
    && chown -R ${STARROCKS_USER}:${STARROCKS_GROUP} ${STARROCKS_ROOT}

USER ${STARROCKS_USER}

COPY --from=artifacts --chown=${STARROCKS_USER}:${STARROCKS_GROUP} /release/be_artifacts/ ${STARROCKS_ROOT}/
COPY --chown=${STARROCKS_USER}:${STARROCKS_GROUP} *.sh ${STARROCKS_ROOT}/

# BE storage dir + cn->be symlink so this image also serves the Operator's CN role.
RUN mkdir -p ${STARROCKS_ROOT}/be/storage && ln -sfT be ${STARROCKS_ROOT}/cn

USER root
```

- [ ] **Step 3: Write `images/starrocks-be-ubi9/smoke.sh` and `smoke-cmd`**

`smoke.sh`:
```bash
#!/usr/bin/env bash
# Fast, deterministic smoke gate for the BE image (must exit 0).
# Exercises the centos7-compiled native binary against UBI9 glibc: assert every
# shared library resolves (no "not found"), which fails closed on a glibc/SONAME
# mismatch — the #1 repackaging risk.
set -euo pipefail
bin=/opt/starrocks/be/lib/starrocks_be
test -x "$bin"
if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
test -L /opt/starrocks/cn
echo "starrocks-be-ubi9 smoke OK"
```
`smoke-cmd`:
```
bash smoke.sh
```
Then: `chmod +x images/starrocks-be-ubi9/smoke.sh`

- [ ] **Step 4: Build + verify (native-binary glibc gate)**

Run:
```bash
podman build -t localhost/smoke/starrocks-be-ubi9:4.1.1 images/starrocks-be-ubi9
podman run --rm -w /opt/starrocks localhost/smoke/starrocks-be-ubi9:4.1.1 bash smoke.sh
# Optional: observe whether the binary exposes a clean --version to upgrade the gate
podman run --rm localhost/smoke/starrocks-be-ubi9:4.1.1 /opt/starrocks/be/lib/starrocks_be --version || true
```
Expected: build succeeds; smoke prints `starrocks-be-ubi9 smoke OK` and exits 0, proving the centos7 BE binary links on UBI9 glibc. If `ldd` reports `not found`, the glibc/SONAME risk has materialized — record which library and stop for design review (do not paper over with `|| true`).

- [ ] **Step 5: Write `images/starrocks-be-ubi9/image.yaml`**

```yaml
name: starrocks-be-ubi9
description: StarRocks BE (Backend) on UBI9
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: registry.access.redhat.com
  repository: ubi9/ubi
  version: "9.8"
runtime:
  name: starrocks-be
tags:
  - "4.1"
  - "4.1.1"
  - "3.3"
  - "3.3.22"
  - "latest"
build_matrix:
  arg: STARROCKS_VERSION
  versions:
    - version: "4.1.1"
      tags: ["4.1", "4.1.1", "latest"]
    - version: "3.3.22"
      tags: ["3.3", "3.3.22"]
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 6: Write `images/starrocks-be-ubi9/README.md`**

```markdown
# starrocks-be-ubi9

StarRocks BE (Backend; shared-nothing storage+compute) repackaged onto Red Hat UBI9,
for deployment via the StarRocks Kubernetes Operator. This image also serves the
Operator's **CN** (compute node) role: it bundles `cn_entrypoint.sh` and a `cn -> be`
symlink (faithful to upstream `be-ubi`).

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/be/be-ubi.Dockerfile`, adapted UBI8 -> UBI9 by repackaging
`starrocks/artifacts-centos7`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/starrocks-be-ubi9:4.1.1
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `4.1.1` / `4.1` | StarRocks 4.1.1, latest UBI9 patch |
| `3.3.22` / `3.3` | StarRocks 3.3.22, latest UBI9 patch |
| `latest` | Latest StarRocks (4.1 line), latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | StarRocks BE (native, centos7 artifacts) + OpenJDK 11 |
| Platforms | linux/amd64 |
| StarRocks Home | `/opt/starrocks` (`be/storage` for data; `cn -> be`) |
| Default command | none — supplied by the Operator |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-be-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
```

- [ ] **Step 7: Lint + policy-check**

Run:
```bash
pixi run -- hadolint --config .hadolint.yaml images/starrocks-be-ubi9/Containerfile
pixi run -- conftest test --policy policy/ --parser dockerfile images/starrocks-be-ubi9/Containerfile
pixi run -- conftest test --policy policy/image-meta/ --namespace image_meta images/starrocks-be-ubi9/image.yaml
bash tests/test-base-images-pinned.sh
```
Expected: all clean / `0 failures` / pin test PASS.

- [ ] **Step 8: Commit**

```bash
git add images/starrocks-be-ubi9
git commit -m "feat(starrocks-be-ubi9): StarRocks BE (and CN role) on UBI9 (4.1.1 + 3.3.22) (#29)"
```

---

## Task 3: CN image (`starrocks-cn-ubi9`)

BE-derived compute node (shared-data). Same artifacts as BE; compute-only (no `be/storage`), CN scripts only.

**Files:**
- Create: `images/starrocks-cn-ubi9/{Containerfile,image.yaml,README.md,smoke-cmd,smoke.sh}`
- Create (vendored): `cn_entrypoint.sh`, `cn_prestop.sh`, `upload_coredump.sh`

- [ ] **Step 1: Vendor the upstream CN scripts**

```bash
mkdir -p images/starrocks-cn-ubi9
for f in cn_entrypoint.sh cn_prestop.sh upload_coredump.sh; do
  gh api "repos/StarRocks/starrocks/contents/docker/dockerfiles/be/${f}?ref=4.1.1" \
    -H "Accept: application/vnd.github.raw" > "images/starrocks-cn-ubi9/${f}"
done
chmod +x images/starrocks-cn-ubi9/*.sh
```

- [ ] **Step 2: Write `images/starrocks-cn-ubi9/Containerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
#
# StarRocks CN (Compute Node, shared-data) on UBI9
# Blueprint: StarRocks/starrocks docker/dockerfiles/be/be-ubi.Dockerfile (ref 4.1.1),
#            specialized for the compute-only CN role (upstream ships CN from the BE
#            artifacts with cn_entrypoint.sh).
# Changes: ubi8/ubi:8.7 -> ubi9/ubi:9.8 (index-digest pinned); yum -> dnf + cache
#          cleanup; MySQL release RPM el8 -> el9; java-1.8.0 -> java-11; dual digest-
#          pinned artifact stages selected by ARG STARROCKS_VERSION.
#
FROM starrocks/artifacts-centos7:4.1.1@sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a AS artifacts-4.1.1
FROM starrocks/artifacts-centos7:3.3.22@sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3 AS artifacts-3.3.22

ARG STARROCKS_VERSION=4.1.1
FROM artifacts-${STARROCKS_VERSION} AS artifacts
RUN rm -f /release/be_artifacts/be/lib/starrocks_be.debuginfo

FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08

ARG STARROCKS_VERSION
ARG STARROCKS_ROOT=/opt/starrocks
ARG STARROCKS_USER=starrocks
ARG STARROCKS_GROUP=starrocks

LABEL org.opencontainers.image.title="starrocks-cn-ubi9"
LABEL org.opencontainers.image.description="StarRocks CN (Compute Node) ${STARROCKS_VERSION} on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# hadolint ignore=DL3041
RUN dnf install -y --nodocs --setopt=install_weak_deps=0 \
        java-11-openjdk-devel \
        tzdata openssl curl vim-minimal ca-certificates fontconfig \
        gzip tar less hostname procps-ng lsof \
    && rpm -ivh https://repo.mysql.com/mysql80-community-release-el9-1.noarch.rpm \
    && dnf install -y --nodocs --nogpgcheck mysql-community-client \
    && dnf remove -y mysql80-community-release \
    && dnf upgrade -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

ENV JAVA_HOME=/usr/lib/jvm/java-11

RUN touch /.dockerenv

WORKDIR ${STARROCKS_ROOT}

RUN groupadd --gid 1000 ${STARROCKS_GROUP} \
    && useradd --no-create-home --uid 1000 --gid 1000 --shell /usr/sbin/nologin ${STARROCKS_USER} \
    && chown -R ${STARROCKS_USER}:${STARROCKS_GROUP} ${STARROCKS_ROOT}

USER ${STARROCKS_USER}

COPY --from=artifacts --chown=${STARROCKS_USER}:${STARROCKS_GROUP} /release/be_artifacts/ ${STARROCKS_ROOT}/
COPY --chown=${STARROCKS_USER}:${STARROCKS_GROUP} *.sh ${STARROCKS_ROOT}/

# CN runs compute-only; expose it under the conventional cn path.
RUN ln -sfT be ${STARROCKS_ROOT}/cn

USER root
```

- [ ] **Step 3: Write `images/starrocks-cn-ubi9/smoke.sh` and `smoke-cmd`**

`smoke.sh` (identical glibc gate as BE; CN uses the BE binary):
```bash
#!/usr/bin/env bash
# Fast, deterministic smoke gate for the CN image (must exit 0).
set -euo pipefail
bin=/opt/starrocks/be/lib/starrocks_be
test -x "$bin"
if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
test -x /opt/starrocks/be/bin/start_cn.sh
echo "starrocks-cn-ubi9 smoke OK"
```
`smoke-cmd`:
```
bash smoke.sh
```
Then `chmod +x images/starrocks-cn-ubi9/smoke.sh`. Note: if Task 0 Step 4 shows `start_cn.sh` is absent in 4.1.1 artifacts, replace that line with `test -x /opt/starrocks/be/bin/start_be.sh`.

- [ ] **Step 4: Build + verify**

Run:
```bash
podman build -t localhost/smoke/starrocks-cn-ubi9:4.1.1 images/starrocks-cn-ubi9
podman run --rm -w /opt/starrocks localhost/smoke/starrocks-cn-ubi9:4.1.1 bash smoke.sh
```
Expected: `starrocks-cn-ubi9 smoke OK`, exit 0.

- [ ] **Step 5: Write `images/starrocks-cn-ubi9/image.yaml`**

```yaml
name: starrocks-cn-ubi9
description: StarRocks CN (Compute Node) on UBI9
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: registry.access.redhat.com
  repository: ubi9/ubi
  version: "9.8"
runtime:
  name: starrocks-cn
tags:
  - "4.1"
  - "4.1.1"
  - "3.3"
  - "3.3.22"
  - "latest"
build_matrix:
  arg: STARROCKS_VERSION
  versions:
    - version: "4.1.1"
      tags: ["4.1", "4.1.1", "latest"]
    - version: "3.3.22"
      tags: ["3.3", "3.3.22"]
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 6: Write `images/starrocks-cn-ubi9/README.md`**

```markdown
# starrocks-cn-ubi9

StarRocks CN (Compute Node; shared-data / storage-compute separation) repackaged onto
Red Hat UBI9, for deployment via the StarRocks Kubernetes Operator (`starRocksCnSpec`).
CN shares the BE binary, started in compute-only mode via `cn_entrypoint.sh`.

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/be/be-ubi.Dockerfile` (CN role), adapted UBI8 -> UBI9 by
repackaging `starrocks/artifacts-centos7`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/starrocks-cn-ubi9:4.1.1
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `4.1.1` / `4.1` | StarRocks 4.1.1, latest UBI9 patch |
| `3.3.22` / `3.3` | StarRocks 3.3.22, latest UBI9 patch |
| `latest` | Latest StarRocks (4.1 line), latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | StarRocks CN (BE binary, compute-only) + OpenJDK 11 |
| Platforms | linux/amd64 |
| StarRocks Home | `/opt/starrocks` (`cn -> be`) |
| Default command | none — supplied by the Operator |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-cn-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
```

- [ ] **Step 7: Lint + policy-check**

Run:
```bash
pixi run -- hadolint --config .hadolint.yaml images/starrocks-cn-ubi9/Containerfile
pixi run -- conftest test --policy policy/ --parser dockerfile images/starrocks-cn-ubi9/Containerfile
pixi run -- conftest test --policy policy/image-meta/ --namespace image_meta images/starrocks-cn-ubi9/image.yaml
bash tests/test-base-images-pinned.sh
```
Expected: all clean / `0 failures` / pin test PASS.

- [ ] **Step 8: Commit**

```bash
git add images/starrocks-cn-ubi9
git commit -m "feat(starrocks-cn-ubi9): StarRocks CN on UBI9 (4.1.1 + 3.3.22) (#29)"
```

---

## Task 4: allin1 image (`starrocks-allin1-ubi9`)

Single-node demo: FE+BE under supervisor with an nginx feproxy. WORKDIR is `/data/deploy` (upstream convention), SR_HOME `/data/deploy/starrocks`.

**Files:**
- Create: `images/starrocks-allin1-ubi9/{Containerfile,image.yaml,README.md,smoke-cmd,smoke.sh}`
- Create (vendored): `entrypoint.sh`, `health_check.sh`, `be.conf`, `fe.conf`, `banner.txt`, `services/director/run.sh`, `services/feproxy/feproxy.conf.template`, `services/supervisor/supervisord.conf`

- [ ] **Step 1: Vendor the upstream allin1 files + services tree**

```bash
mkdir -p images/starrocks-allin1-ubi9/services/director \
         images/starrocks-allin1-ubi9/services/feproxy \
         images/starrocks-allin1-ubi9/services/supervisor
base="repos/StarRocks/starrocks/contents/docker/dockerfiles/allin1"
for f in entrypoint.sh health_check.sh be.conf fe.conf banner.txt; do
  gh api "${base}/${f}?ref=4.1.1" -H "Accept: application/vnd.github.raw" \
    > "images/starrocks-allin1-ubi9/${f}"
done
gh api "${base}/services/director/run.sh?ref=4.1.1" -H "Accept: application/vnd.github.raw" \
  > images/starrocks-allin1-ubi9/services/director/run.sh
gh api "${base}/services/feproxy/feproxy.conf.template?ref=4.1.1" -H "Accept: application/vnd.github.raw" \
  > images/starrocks-allin1-ubi9/services/feproxy/feproxy.conf.template
gh api "${base}/services/supervisor/supervisord.conf?ref=4.1.1" -H "Accept: application/vnd.github.raw" \
  > images/starrocks-allin1-ubi9/services/supervisor/supervisord.conf
chmod +x images/starrocks-allin1-ubi9/*.sh images/starrocks-allin1-ubi9/services/director/run.sh
```
Expected: five top-level files + three service files, all non-empty.

- [ ] **Step 2: Write `images/starrocks-allin1-ubi9/Containerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
#
# StarRocks allin1 (single-node demo) on UBI9
# Blueprint: StarRocks/starrocks docker/dockerfiles/allin1/allin1-ubi.Dockerfile (ref 4.1.1)
# Changes: ubi8/ubi:8.7 -> ubi9/ubi:9.8 (index-digest pinned); yum -> dnf + cache
#          cleanup; MySQL release RPM el8 -> el9; pip supervisor version-pinned;
#          dual digest-pinned artifact stages selected by ARG STARROCKS_VERSION.
#
FROM starrocks/artifacts-centos7:4.1.1@sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a AS artifacts-4.1.1
FROM starrocks/artifacts-centos7:3.3.22@sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3 AS artifacts-3.3.22

ARG STARROCKS_VERSION=4.1.1
FROM artifacts-${STARROCKS_VERSION} AS artifacts
RUN rm -f /release/be_artifacts/be/lib/starrocks_be.debuginfo

FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee85eaa34762a1ae317661efedd8a8dabd4fd84ad17676669920e4270aa08

ARG STARROCKS_VERSION
ARG DEPLOYDIR=/data/deploy
ENV SR_HOME=${DEPLOYDIR}/starrocks

LABEL org.opencontainers.image.title="starrocks-allin1-ubi9"
LABEL org.opencontainers.image.description="StarRocks allin1 (single-node demo) ${STARROCKS_VERSION} on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# hadolint ignore=DL3041
RUN dnf install -y --nodocs --setopt=install_weak_deps=0 \
        java-11-openjdk-devel \
        tzdata openssl curl vim-minimal ca-certificates fontconfig \
        gzip tar less hostname procps-ng lsof nmap-ncat \
        python3-pip nginx \
    && rpm -ivh https://repo.mysql.com/mysql80-community-release-el9-1.noarch.rpm \
    && dnf install -y --nodocs --nogpgcheck mysql-community-client \
    && dnf remove -y mysql80-community-release \
    && dnf upgrade -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum \
    && pip3 install --no-cache-dir supervisor==4.2.5

ENV JAVA_HOME=/usr/lib/jvm/java-11

WORKDIR ${DEPLOYDIR}

# Copy BE then FE artifacts into the shared SR_HOME (matches upstream allin1 layout).
COPY --from=artifacts /release/be_artifacts/ ${DEPLOYDIR}/starrocks
COPY --from=artifacts /release/fe_artifacts/ ${DEPLOYDIR}/starrocks

# Vendored setup scripts, configs, and the supervisor/feproxy/director service tree.
COPY *.sh *.conf *.txt ${DEPLOYDIR}/
COPY services/ ${SR_HOME}/

RUN cat be.conf >> ${DEPLOYDIR}/starrocks/be/conf/be.conf \
    && cat fe.conf >> ${DEPLOYDIR}/starrocks/fe/conf/fe.conf \
    && rm -f be.conf fe.conf \
    && mkdir -p ${DEPLOYDIR}/starrocks/fe/meta ${DEPLOYDIR}/starrocks/be/storage \
    && touch /.dockerenv

CMD ["./entrypoint.sh"]
```

- [ ] **Step 3: Write `images/starrocks-allin1-ubi9/smoke.sh` and `smoke-cmd`**

The default `CMD ["./entrypoint.sh"]` starts a full cluster (too slow/heavy for smoke); `smoke-cmd` overrides it with a fast gate. `smoke.sh`:
```bash
#!/usr/bin/env bash
# Fast, deterministic smoke gate for the allin1 image (must exit 0).
set -euo pipefail
bin=/data/deploy/starrocks/be/lib/starrocks_be
test -x "$bin"
if ldd "$bin" 2>&1 | grep -q 'not found'; then
  echo "FAIL: unresolved shared libraries for $bin"; ldd "$bin" | grep 'not found'; exit 1
fi
java -version
command -v supervisord
command -v nginx
test -f /data/deploy/starrocks/fe/lib/starrocks-fe.jar
echo "starrocks-allin1-ubi9 smoke OK"
```
`smoke-cmd`:
```
bash smoke.sh
```
Then `chmod +x images/starrocks-allin1-ubi9/smoke.sh`.

- [ ] **Step 4: Build + verify**

Run:
```bash
podman build -t localhost/smoke/starrocks-allin1-ubi9:4.1.1 images/starrocks-allin1-ubi9
podman run --rm -w /data/deploy localhost/smoke/starrocks-allin1-ubi9:4.1.1 bash smoke.sh
```
Expected: build succeeds; smoke prints paths for `supervisord`/`nginx` and `starrocks-allin1-ubi9 smoke OK`, exit 0. If `cat be.conf >> .../be/conf/be.conf` fails (path differs in artifacts), inspect `/data/deploy/starrocks/be/conf/` from Task 0 Step 4 output and adjust.

- [ ] **Step 5: Write `images/starrocks-allin1-ubi9/image.yaml`**

```yaml
name: starrocks-allin1-ubi9
description: StarRocks allin1 single-node demo on UBI9
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: registry.access.redhat.com
  repository: ubi9/ubi
  version: "9.8"
runtime:
  name: starrocks-allin1
tags:
  - "4.1"
  - "4.1.1"
  - "3.3"
  - "3.3.22"
  - "latest"
build_matrix:
  arg: STARROCKS_VERSION
  versions:
    - version: "4.1.1"
      tags: ["4.1", "4.1.1", "latest"]
    - version: "3.3.22"
      tags: ["3.3", "3.3.22"]
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 6: Write `images/starrocks-allin1-ubi9/README.md`**

```markdown
# starrocks-allin1-ubi9

StarRocks **allin1** single-node image (FE + BE under supervisor, with an nginx
feproxy) repackaged onto Red Hat UBI9. Intended for local development, demos, and
CI — **not** for Operator-managed production clusters (use `starrocks-fe-ubi9` /
`starrocks-be-ubi9` / `starrocks-cn-ubi9` for that).

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/allin1/allin1-ubi.Dockerfile`, adapted UBI8 -> UBI9 by
repackaging `starrocks/artifacts-centos7`.

## Run

```bash
podman run -p 9030:9030 -p 8030:8030 ghcr.io/nq-rdl/starrocks-allin1-ubi9:4.1.1
# MySQL protocol on :9030, FE HTTP on :8030
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `4.1.1` / `4.1` | StarRocks 4.1.1, latest UBI9 patch |
| `3.3.22` / `3.3` | StarRocks 3.3.22, latest UBI9 patch |
| `latest` | Latest StarRocks (4.1 line), latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | StarRocks FE+BE + OpenJDK 11, supervisor, nginx feproxy |
| Platforms | linux/amd64 |
| Deploy dir | `/data/deploy/starrocks` |
| Default command | `./entrypoint.sh` (starts the single-node cluster) |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-allin1-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
```

- [ ] **Step 7: Lint + policy-check**

Run:
```bash
pixi run -- hadolint --config .hadolint.yaml images/starrocks-allin1-ubi9/Containerfile
pixi run -- conftest test --policy policy/ --parser dockerfile images/starrocks-allin1-ubi9/Containerfile
pixi run -- conftest test --policy policy/image-meta/ --namespace image_meta images/starrocks-allin1-ubi9/image.yaml
bash tests/test-base-images-pinned.sh
```
Expected: all clean / `0 failures` / pin test PASS. (If hadolint flags `DL3013` despite the `==4.2.5` pin, add `# hadolint ignore=DL3013` above the RUN.)

- [ ] **Step 8: Commit**

```bash
git add images/starrocks-allin1-ubi9
git commit -m "feat(starrocks-allin1-ubi9): StarRocks allin1 single-node on UBI9 (4.1.1 + 3.3.22) (#29)"
```

---

## Task 5: Verify the 3.3.22 matrix variant builds

The local smoke harness only builds the default (4.1.1). Confirm the other matrix line builds via the build-arg the way `build.yml` invokes it.

**Files:** none.

- [ ] **Step 1: Build each image's 3.3.22 variant**

Run:
```bash
for img in fe be cn allin1; do
  echo "== starrocks-${img}-ubi9 @ 3.3.22 =="
  podman build --build-arg STARROCKS_VERSION=3.3.22 \
    -t "localhost/smoke/starrocks-${img}-ubi9:3.3.22" "images/starrocks-${img}-ubi9"
done
```
Expected: all four build successfully, pulling only the `artifacts-3.3.22` stage (BuildKit prunes `artifacts-4.1.1`).

- [ ] **Step 2: Smoke the 3.3.22 native binary (glibc gate on the older line)**

Run:
```bash
podman run --rm -w /opt/starrocks localhost/smoke/starrocks-be-ubi9:3.3.22 bash smoke.sh
podman run --rm -w /opt/starrocks localhost/smoke/starrocks-fe-ubi9:3.3.22 bash smoke.sh
```
Expected: both print `... smoke OK`, exit 0. If a vendored script materially differs between 3.3 and 4.1 (per spec §8), split per-version using the same stage-selector trick; otherwise the shared 4.1.1 scripts stand. Record the decision.

- [ ] **Step 3: No commit** (verification only).

---

## Task 6: Repo-wide checks + changelog

**Files:**
- Create: `.changes/unreleased/Added-<timestamp>.yaml`
- Possibly modify: `.pre-commit-config.yaml` (only if Task 0 Step 1 found shellcheck globs `images/`)

- [ ] **Step 1: Add the changie fragment**

Run:
```bash
pixi run -- changie new --kind Added \
  --body "Add StarRocks UBI9 images (starrocks-fe/be/cn/allin1-ubi9), StarRocks 4.1.1 (latest) and 3.3.22, repackaged from artifacts-centos7 onto ubi9/ubi:9.8 for StarRocks Operator deployments (#29)"
```
Expected: a new `.changes/unreleased/Added-*.yaml`. If `changie` is unavailable, create the file manually mirroring `.changes/unreleased/Added-20260526-124638.yaml` (fields: `kind: Added`, `body: '...'`, `time: <RFC3339>`).

- [ ] **Step 2: Scope shellcheck off vendored scripts if needed**

Only if Task 0 Step 1 found the pre-commit `shellcheck` hook globs `images/`: add `exclude: ^images/.*\.(sh)$` to that hook in `.pre-commit-config.yaml` (vendored upstream scripts are not ours to restyle). Otherwise skip.

- [ ] **Step 3: Run the full lint/policy suite**

Run:
```bash
pixi run lint-all
```
Expected: `lint-containerfiles`, `lint-shell`, `lint-actions`, and all four `policy-check-*` tasks pass. Fix any failure in the offending file and re-run.

- [ ] **Step 4: Run the smoke harness (k3d optional)**

Run:
```bash
make install-deps   # installs k3d/kubectl if missing
pixi run smoke-test
```
Expected: Phase 1 builds all four images; Phase 2 runs each with `bash smoke.sh` → `... smoke OK`; Phase 3 imports into k3d and each pod reaches Succeeded. If this environment cannot run k3d, run Phases 1–2 by building + `podman run ... bash smoke.sh` per image (Tasks 1–4 Step 4 already cover this) and note that Phase 3 is delegated to CI `build.yml`.

- [ ] **Step 5: Trivy scan (informational; CI is non-blocking)**

Run:
```bash
pixi run trivy-scan || true
```
Expected: review CRITICAL/HIGH fixable findings. CI uploads SARIF with `exit-code: 0` (non-blocking), but the local pre-push hook blocks — if it blocks on findings already mitigated by `dnf upgrade -y`, document them and push with `SKIP_TRIVY=1` (recording the justification).

- [ ] **Step 6: Commit changelog (+ any pre-commit config change)**

```bash
git add .changes/unreleased .pre-commit-config.yaml 2>/dev/null || git add .changes/unreleased
git commit -m "docs(changelog): add StarRocks UBI9 images fragment (#29)"
```

---

## Task 7: Push and open the PR

**Files:** none.

- [ ] **Step 1: Push the branch**

Run:
```bash
git push -u origin feat/starrocks-ubi9-images
```
Expected: pre-push hooks (changie-required, smoke, trivy) run. Use `SKIP_SMOKE=1`/`SKIP_TRIVY=1` only if a hook blocks for an environment reason already validated above, and state which flags were used and why in the PR body.

- [ ] **Step 2: Open the PR**

Run:
```bash
gh pr create --base main --head feat/starrocks-ubi9-images \
  --title "feat(starrocks): StarRocks UBI9 images — FE/BE/CN/allin1 (4.1.1 + 3.3.22) (#29)" \
  --body "$(cat <<'EOF'
## Summary
Adds four StarRocks images on UBI9, closing #29:
- `starrocks-fe-ubi9`, `starrocks-be-ubi9` (also serves CN role), `starrocks-cn-ubi9`, `starrocks-allin1-ubi9`
- Two version lines each via `build_matrix`: **4.1.1** (carries `latest`) and **3.3.22**
- Repackaged from `starrocks/artifacts-centos7:<ver>` onto `ubi9/ubi:9.8` (index-digest pinned); `linux/amd64`

## Approach
Upstream's `*-ubi.Dockerfile`s repackage prebuilt `artifacts-centos7` rather than compiling from source; this PR mirrors that, adapting UBI8 -> UBI9 (dnf, el9 MySQL repo, JDK 11). centos7 artifacts (glibc 2.17) run forward-safely on UBI9 (glibc 2.34); the BE/CN smoke gate asserts the native binary's libraries resolve.

## Verification
- hadolint + conftest (base/labels/tags) + `test-base-images-pinned.sh` green
- Both matrix lines (4.1.1, 3.3.22) build; FE/BE/CN/allin1 smoke gates pass on amd64
- Design spec: `docs/superpowers/specs/2026-06-04-starrocks-ubi9-images-design.md`

Closes #29.
EOF
)"
```
Expected: PR created against `main`. CI (`build.yml` discover→build matrix of 8, `validate-base-pins`, `hadolint`, `lint`, `policy`) runs on the PR.

- [ ] **Step 3: Report CI status**

Run: `gh pr checks --watch`
Expected: report pass/fail per check to the user; triage any failure against the relevant task above.

---

## Self-Review notes (author)

- **Spec coverage:** 4 images (Tasks 1–4); two version lines incl. `latest`→4.1.1 (image.yaml `build_matrix` + Task 5); UBI9 standard digest-pinned (all Containerfiles); amd64-only (`platforms`); artifact repackage (all); dual-stage selector + pin-test exemption (all Containerfiles + Task 1 Step 7); smoke strategy incl. glibc gate (smoke.sh in each); UBI8→UBI9 adaptations (Containerfile headers + Task 0); vendored scripts (Tasks 1–4 Step 1); changie Added (Task 6); no dependabot entry (matches repo); CI/policy compliance (per-task Step 7 + Task 6). All spec sections map to a task.
- **Placeholder scan:** the only deferred values (`JAVA_HOME` path, el9 MySQL RPM `-N`, `start_cn.sh` presence) are each resolved by an explicit Task 0 discovery step with the exact command and substitution rule — not open-ended TODOs.
- **Consistency:** image dir names, `STARROCKS_VERSION` arg, tag sets, `/opt/starrocks` (fe/be/cn) vs `/data/deploy/starrocks` (allin1), and `smoke-cmd`=`bash smoke.sh` are uniform across tasks.
