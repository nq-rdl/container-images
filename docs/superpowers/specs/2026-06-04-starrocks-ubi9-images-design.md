# StarRocks UBI9 images

- **Date:** 2026-06-04
- **Status:** Approved (design)
- **Branch:** `feat/starrocks-ubi9-images`
- **Closes:** Issue #29 (*Request: StarRocks Images*)

## 1. Problem

Issue #29 requests StarRocks container images on **UBI9 (standard)** for deploying
and managing StarRocks via the **StarRocks Operator**, linux/amd64, HIGH priority.
It links the upstream UBI Dockerfiles for `allin1`, `be`, and `fe`.

Two facts shape the whole design:

1. **The upstream `*-ubi.Dockerfile`s do not compile StarRocks.** They copy
   pre-built binaries from an *artifact image* (`starrocks/artifacts-centos7:<ver>`)
   or a local build tree. Compiling from source needs StarRocks' multi-GB `dev-env`
   toolchain (Maven FE + C++ BE) and is not viable in this repo's lightweight
   `podman build` + smoke-test CI.
2. **The upstream `*-ubi` runtime images are UBI8 (`ubi8/ubi:8.7`) and frozen at
   3.3.0** on Docker Hub. The actively-maintained runtimes are the Ubuntu ones.
   `starrocks/artifacts-centos7`, by contrast, is current (3.3.22 … 4.1.1).

So the value this PR delivers is **current StarRocks repackaged onto a pinned,
Trivy-scanned, attested UBI9 base from GHCR** — exactly what upstream's own
`fe-ubi.Dockerfile` does (`FROM ${ARTIFACTIMAGE}`), but on UBI9 instead of UBI8.

## 2. Goals / Non-goals

**Goals**

- Add four images: `starrocks-fe-ubi9`, `starrocks-be-ubi9`, `starrocks-cn-ubi9`,
  `starrocks-allin1-ubi9`.
- Two version lines each via `build_matrix`: **4.1.1** (carries `latest`) and
  **3.3.22**.
- Final base `registry.access.redhat.com/ubi9/ubi:9.8`, pinned by index digest.
- Repackage `starrocks/artifacts-centos7:<ver>` (index-digest pinned).
- `linux/amd64` only (per the issue).
- Pass all repo policies/lints (pin tests, base policy, labels, tag patterns,
  hadolint) and the smoke-test harness.
- One changie fragment (kind **Added**).

**Non-goals**

- Building StarRocks from source (rejected — see §3).
- `linux/arm64` (not requested).
- Full multi-node cluster bring-up in smoke tests (out of scope — see §7).
- A `.github/dependabot.yml` entry (the repo's existing images have none; base
  digests are maintained by `base-drift.yml`, not dependabot — see §8).

## 3. Approaches considered

| # | Approach | Verdict |
|---|----------|---------|
| A | **Repackage published artifacts** onto UBI9 (`FROM artifacts-centos7:<ver>` → copy onto `ubi9/ubi`) | **Chosen.** Mirrors upstream, tractable in CI, ships current versions. |
| B | Build from source (replicate `artifact.Dockerfile`) | Rejected — needs the multi-GB `dev-env` toolchain; tens-of-minutes builds; won't fit this CI. |
| C | Re-tag upstream `*-ubi` runtime images | Rejected — UBI8 and frozen at 3.3.0; fails the UBI9 requirement. |

**Why centos7 artifacts (not ubuntu):** centos7 targets glibc 2.17 — the *oldest*
target — and glibc runs older binaries on newer systems. UBI9 is glibc 2.34, so
centos7 binaries run forward safely; ubuntu artifacts (glibc ≥2.35) would *fail* on
UBI9. This is exactly why upstream feeds centos7 artifacts into its UBI image.

## 4. Image set

Four directories under `images/`, each a `build_matrix` of the two versions
(2 versions × 4 components = **8 builds** in CI):

| Directory | Role | Artifacts consumed |
|-----------|------|--------------------|
| `starrocks-fe-ubi9` | Frontend / coordinator (JVM) | `/release/fe_artifacts` |
| `starrocks-be-ubi9` | Backend, shared-nothing (C++ + JVM); bundles CN scripts + `cn→be` symlink (faithful to upstream `be-ubi`) | `/release/be_artifacts` |
| `starrocks-cn-ubi9` | Compute Node, shared-data (BE binary, compute-only) | `/release/be_artifacts` |
| `starrocks-allin1-ubi9` | Single-node demo (FE+BE+supervisor+nginx feproxy) | both |

The BE image already covers the Operator's CN role (it bundles `cn_entrypoint.sh`
and the `cn→be` symlink); the dedicated `starrocks-cn-ubi9` mirrors upstream's
separate `cn-ubuntu` repo for clarity in Operator manifests.

## 5. Pinned references (index digests, all amd64-covering)

| Reference | Index digest |
|-----------|--------------|
| `registry.access.redhat.com/ubi9/ubi:9.8` | `sha256:80b1f4c34a7eed1b03a05d12b55768f3e522eef6ec294c6fbd5fa47b6b2892ee` |
| `starrocks/artifacts-centos7:4.1.1` | `sha256:5b8e1dc0bc38544c2c618492e686b7f8903a7f8bbe09afdeaff7f2a78a46e66a` |
| `starrocks/artifacts-centos7:3.3.22` | `sha256:ccdf388ffe57a6dab771b95fb296ecf1df2bb4249e8961f05909cadaee61d3e3` |

(Digests re-verified at implementation time; `base-drift.yml` maintains the UBI pin
thereafter.)

## 6. Containerfile pattern

The repo's `build_matrix` passes a single `ARG=version` build-arg, but
`tests/test-base-images-pinned.sh` forbids `${...}` in any external `FROM` and
requires a literal `@sha256:`. The reconciliation: declare **two literal,
digest-pinned artifact stages** and select between them with a **stage-ref FROM**
(which the pin test exempts because it has no `/`, `.`, `:`, or `@`):

```dockerfile
# syntax=docker/dockerfile:1.7
#
# StarRocks <component> on UBI9
# Blueprint: StarRocks/starrocks docker/dockerfiles/<component>/<component>-ubi.Dockerfile
# Changes: ubi8/ubi:8.7 -> ubi9/ubi:9.8 (digest-pinned index); yum -> dnf + cache
#          cleanup; mysql repo el8 -> el9; BE java-1.8.0 -> java-11; dual digest-
#          pinned artifact stages selected by ARG for the build_matrix.
#
FROM starrocks/artifacts-centos7:4.1.1@sha256:5b8e1d…  AS artifacts-4.1.1
FROM starrocks/artifacts-centos7:3.3.22@sha256:ccdf38… AS artifacts-3.3.22
ARG STARROCKS_VERSION=4.1.1
FROM artifacts-${STARROCKS_VERSION} AS artifacts            # stage selector (pin-test exempt)

FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:ef3ee8…   # final FROM → UBI (policy)
ARG STARROCKS_VERSION
LABEL org.opencontainers.image.title="starrocks-<component>-ubi9"
LABEL org.opencontainers.image.description="StarRocks <Component> ${STARROCKS_VERSION} on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="Apache-2.0"
RUN dnf install -y --setopt=install_weak_deps=0 --nodocs <packages> \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/yum
COPY --from=artifacts /release/<fe|be>_artifacts/ /opt/starrocks/
COPY *.sh /opt/starrocks/        # vendored Operator scripts
# users/dirs/symlinks per upstream; no server-starting default command
```

BuildKit prunes the unselected artifact stage, so building 3.3.22 does **not** pull
the 4.1.1 (~4.7 GB) image, and the no-build-arg local smoke build uses the default
(4.1.1) only.

### image.yaml (per directory)

```yaml
name: starrocks-<component>-ubi9
description: StarRocks <Component> on UBI9
owners: [nq-rdl/platform, nq-rdl/data-engineering]
platforms: [linux/amd64]
base: { registry: registry.access.redhat.com, repository: ubi9/ubi, version: "9.8" }
runtime: { name: starrocks-<component> }
tags: ["4.1", "4.1.1", "3.3", "3.3.22", "latest"]   # union → satisfies tags policy
build_matrix:
  arg: STARROCKS_VERSION
  versions:
    - { version: "4.1.1", tags: ["4.1", "4.1.1", "latest"] }
    - { version: "3.3.22", tags: ["3.3", "3.3.22"] }
support: { status: stable, eol: "2027-06-30" }   # one block per image (tracks the latest/4.1 line; best-effort)
```

## 7. UBI8→UBI9 adaptations (documented in each Containerfile header)

- `ubi8/ubi:8.7` → `ubi9/ubi:9.8` (index-digest pinned).
- `yum` → `dnf` + `dnf clean all` cleanup. (`.hadolint.yaml` ignores DL3041/dnf
  but not DL3033/yum, so `dnf` avoids a lint failure and is UBI9-idiomatic.)
- MySQL client release RPM `el8` → `el9`.
- BE/CN `java-1.8.0-openjdk` → `java-11-openjdk-headless` (Java 8 is absent from
  UBI9 repos; current upstream BE uses JDK 11). FE/allin1 already use Java 11.
- allin1 `pip3 install supervisor` → version-pinned (avoids hadolint DL3013).
- `dnf upgrade -y` during build to reduce fixable CRITICAL/HIGH Trivy findings.

## 8. Vendored files

Build context is the per-image directory, so upstream `COPY docker/dockerfiles/<c>/*.sh`
flattens to `COPY *.sh`. Vendor from the **4.1.1** ref; diff against 3.3 during
implementation and split per-version (same stage-selector trick) only if materially
different — these are stable Operator glue.

| Image | Vendored files |
|-------|----------------|
| fe | `fe_entrypoint.sh`, `fe_prestop.sh` |
| be | `be_entrypoint.sh`, `be_prestop.sh`, `cn_entrypoint.sh`, `cn_prestop.sh`, `upload_coredump.sh` |
| cn | `cn_entrypoint.sh`, `cn_prestop.sh`, `upload_coredump.sh` |
| allin1 | `entrypoint.sh`, `health_check.sh`, `be.conf`, `fe.conf`, `banner.txt`, `services/**` |

## 9. Smoke tests

`scripts/smoke-test.sh` builds each image (no build-args → default 4.1.1), runs it
with the `smoke-cmd` args (must exit 0 within 60 s; unquoted, space-split — no shell
operators), and runs it as a k3d pod (must reach Succeeded or Running). The images
carry **no server-starting default command** (matches upstream — the Operator supplies
it), so each directory gets a `smoke-cmd` that runs a fast, deterministic, exit-0
check:

- **fe / allin1:** the bundled JVM (`java -version`) + key-artifact presence.
- **be / cn:** invoke the actual `starrocks_be` binary's version/help, so smoke
  genuinely exercises the **centos7→UBI9 glibc compatibility** (the #1 risk).

Exact invocations are validated against the real artifact layout during
implementation (the riskiest verification step).

## 10. CI / policy compliance

- `base_image.rego`: final FROM is `ubi9/ubi` ✓ (artifact stages are earlier, exempt).
- `test-base-images-pinned.sh`: every external FROM is literal `:tag@sha256:` with no
  `${}` ✓; the `artifacts-${STARROCKS_VERSION}` selector is a stage ref → exempt ✓.
- `validate-base-pins.yml`: every `@sha256:` FROM is a multi-arch index covering
  `linux/amd64` ✓ (UBI + both artifact images confirmed).
- `labels.rego`: all five OCI labels; vendor = `Research Data Laboratory` ✓.
- `image-meta/tags.rego`: top-level `tags` all match `X.Y.Z`/`X.Y`/`latest` ✓.
- `build.yml`: `build_matrix.arg: STARROCKS_VERSION` expands to 2 entries/image;
  `version_tags` drive tags incl. `latest` for 4.1.1 ✓.
- One changie fragment, kind **Added**.

## 11. Verification strategy & risks

- **glibc (centos7 binaries on UBI9)** — primary risk; mitigated by smoke actually
  running the BE binary. Direction is the safe one (older→newer glibc).
- **Heavy local builds** — each version pulls ~4.7 GB; 4 images. `docker`/`podman`/
  `skopeo` are present locally; `k3d`/`conftest`/`trivy`/`hadolint` are pixi-managed
  (`make install-deps` / `pixi run`). If local build is infeasible, rely on `build.yml`
  (builds all 8 on the PR); use `SKIP_SMOKE`/`SKIP_TRIVY` for the push **only** if
  necessary, and say so explicitly. At minimum, build the default (4.1.1) variant of
  each image locally to validate the Containerfile + glibc.
- **Trivy CRITICAL/HIGH** — CI uploads SARIF non-blocking (`exit-code: 0`); the local
  pre-push hook blocks on fixable findings. Mitigated by `dnf upgrade -y`.
- **3.3.22 script drift** — diff vendored scripts; split per-version only if needed.

## 12. Rollout

Branch `feat/starrocks-ubi9-images` → single PR (`Closes #29`). On merge to `main`,
`build.yml` builds all 8 variants and points `latest`/`4.1`/`4.1.1` and `3.3`/`3.3.22`
at the new digests; `publish-aliases` creates the suffix-less convenience aliases.
Consumers pin by `@sha256:` digest in Operator manifests.
