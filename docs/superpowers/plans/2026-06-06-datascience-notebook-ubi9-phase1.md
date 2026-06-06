# Datascience-notebook UBI9 — Phase 1 (foundation + base-notebook) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first two UBI9 images of the Jupyter datascience-notebook chain —
`docker-stacks-foundation-ubi9` and `base-notebook-ubi9` — plus the BuildKit/bake + policy
enablement that the whole chain depends on.

**Architecture:** Per-image `Containerfile` (`FROM ${BASE_CONTAINER}`) chained via a root
`docker-bake.hcl` (BuildKit `contexts`). Packages come from **pixi** (conda-forge) with a
committed `pixi.lock` per image; the env prefix is exported as `CONDA_DIR` so upstream's
`start.sh` runtime contract works unmodified. User model: `jovyan` / UID 1000 / **GID 0**
(OpenShift arbitrary-UID friendly). amd64 only.

**Tech Stack:** UBI9 (`registry.access.redhat.com/ubi9/ubi`), pixi 0.47.0, conda-forge,
`tini` 0.19.0 (static binary), JupyterLab/Notebook/JupyterHub-singleuser, `docker buildx
bake`, conftest/OPA (rego), hadolint, Trivy, k3d smoke tests.

**Spec:** `docs/superpowers/specs/2026-06-06-datascience-notebook-ubi9-design.md`

**Pinned upstream:** jupyter/docker-stacks commit
`96322b6b179e4de61eb6ddbbdadcd8fba61662f7` (vendor scripts from this exact SHA).

**Conventions for every commit:** branch `feat/datascience-notebook-ubi9`; conventional-commit
messages; do **not** push until the phase is green (push runs smoke + Trivy + changie gates).

---

## File map (Phase 1)

| Path | Responsibility |
|------|----------------|
| `tests/test-chained-bases-pinned.sh` | New guard: `ARG BASE_CONTAINER` defaults are digest-pinned `ghcr.io/nq-rdl/…` |
| `policy/base_image.rego` | Accept the `${BASE_CONTAINER}` chained-base sentinel (transitive UBI invariant) |
| `policy/base_image_test.rego` | Conftest/OPA unit tests for the rego change |
| `.hadolint.yaml` | Add `ghcr.io` to `trustedRegistries` |
| `pyproject.toml` | Wire the new test into `policy-check` |
| `docker-bake.hcl` | Root bake file: `foundation` + `base-notebook` targets + `datascience` group |
| `images/docker-stacks-foundation-ubi9/` | Foundation image: `Containerfile`, `image.yaml`, `README.md`, `smoke-cmd`, `pixi.toml`, `pixi.lock`, vendored scripts |
| `images/base-notebook-ubi9/` | Base-notebook image: same shape, chained on foundation |
| `.github/workflows/build.yml` | Add a `bake` job for chained images; exclude them from the per-image matrix |
| `scripts/smoke-test.sh` | Build chained images via bake; skip them in the per-image loop |
| `scripts/trivy-scan.sh` | Scan bake-built chained images |
| `.changes/unreleased/Added-*.yaml` | changie fragment |

---

## Task 1: New chained-base pin guard (test-first)

**Files:**
- Create: `tests/test-chained-bases-pinned.sh`
- Modify: `pyproject.toml` (add task + `policy-check` dependency)

- [ ] **Step 1: Write the guard script** (it *is* the test — it asserts a repo invariant)

Create `tests/test-chained-bases-pinned.sh`:

```bash
#!/usr/bin/env bash
# Asserts every `ARG BASE_CONTAINER=` default in images/*/Containerfile is a digest-pinned
# repo-internal base: ghcr.io/nq-rdl/<name>-ubi9:<tag>@sha256:<64-hex>.
# This restores the digest-pin guarantee that test-base-images-pinned.sh drops for the
# `FROM ${BASE_CONTAINER}` stage-ref form used by chained images.
set -euo pipefail

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

re='^ghcr\.io/nq-rdl/[a-z0-9._-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'

shopt -s nullglob
for cf in images/*/Containerfile; do
  # Only Containerfiles that actually chain (declare ARG BASE_CONTAINER) are in scope.
  grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf" || continue
  # Extract the default value of the LAST `ARG BASE_CONTAINER=...` line.
  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//')
  if [ -z "$val" ]; then
    fail "$cf: ARG BASE_CONTAINER has no digest-pinned default"
  elif [[ "$val" =~ $re ]]; then
    pass "$cf: BASE_CONTAINER=$val"
  else
    fail "$cf: BASE_CONTAINER default '$val' is not ghcr.io/nq-rdl/<img>:<tag>@sha256:<digest>"
  fi
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} chained base(s) not properly pinned"; exit 1
else
  echo "All chained bases are digest-pinned (or none present)"; exit 0
fi
```

- [ ] **Step 2: Make it executable and run it (expect PASS on an empty match)**

Run:
```bash
chmod +x tests/test-chained-bases-pinned.sh
bash tests/test-chained-bases-pinned.sh
```
Expected: `All chained bases are digest-pinned (or none present)` (no chained images exist yet → exit 0).

- [ ] **Step 3: Wire it into pixi `policy-check`**

In `pyproject.toml`, under `[tool.pixi.tasks]` add:
```toml
policy-check-chained-bases = "bash tests/test-chained-bases-pinned.sh"
```
and add it to the `policy-check` aggregate:
```toml
[tool.pixi.tasks.policy-check]
depends-on = ["policy-check-containerfiles", "policy-check-image-meta", "policy-check-workflow-tags", "policy-check-base-pinning", "policy-check-chained-bases"]
```

- [ ] **Step 4: Verify the wiring**

Run: `pixi run policy-check-chained-bases`
Expected: exit 0, prints the "All chained bases…" line.

- [ ] **Step 5: Commit**

```bash
git add tests/test-chained-bases-pinned.sh pyproject.toml
git commit -m "test(policy): add chained-base digest-pin guard for ${BASE_CONTAINER} images"
```

---

## Task 2: Allow the `${BASE_CONTAINER}` chained base in `base_image.rego` (test-first)

**Files:**
- Create: `policy/base_image_test.rego`
- Modify: `policy/base_image.rego`

- [ ] **Step 1: Write failing rego unit tests**

Create `policy/base_image_test.rego`:

```rego
package main

# A chained child: final FROM is the ${BASE_CONTAINER} sentinel → must be ALLOWED.
test_allows_base_container_sentinel if {
    count(deny) == 0 with input as [
        {"Cmd": "arg", "Value": ["BASE_CONTAINER=ghcr.io/nq-rdl/docker-stacks-foundation-ubi9:2026.6.0@sha256:abc"]},
        {"Cmd": "from", "Value": ["${BASE_CONTAINER}"]},
    ]
}

# A direct ghcr.io/nq-rdl chained base → ALLOWED.
test_allows_ghcr_internal_base if {
    count(deny) == 0 with input as [
        {"Cmd": "from", "Value": ["ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0@sha256:abc"]},
    ]
}

# A UBI base → still ALLOWED.
test_allows_ubi_base if {
    count(deny) == 0 with input as [
        {"Cmd": "from", "Value": ["registry.access.redhat.com/ubi9/ubi:9.8@sha256:abc"]},
    ]
}

# An arbitrary external base → still DENIED.
test_denies_dockerhub_base if {
    count(deny) == 1 with input as [
        {"Cmd": "from", "Value": ["ubuntu:24.04"]},
    ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pixi run -- conftest verify --policy policy/`  *(or: `conftest verify --policy policy/`)*
Expected: `test_allows_base_container_sentinel` and `test_allows_ghcr_internal_base` FAIL
(current rego denies both); the UBI and dockerhub tests PASS.

- [ ] **Step 3: Edit `policy/base_image.rego`**

Replace the file with:

```rego
package main

import data.helpers

# Repo-internal images under ghcr.io/nq-rdl/ are UBI-rooted by construction: every image
# must pass this policy before it is pushed to GHCR, so a chained FROM is transitively
# UBI-rooted. The chain is written as `ARG BASE_CONTAINER=ghcr.io/nq-rdl/...@sha256:...`
# + `FROM ${BASE_CONTAINER}`; the ARG default's digest pin is enforced by
# tests/test-chained-bases-pinned.sh.
deny contains msg if {
	idx := helpers.final_stage_start
	val := input[idx].Value[0]
	not startswith(val, "registry.access.redhat.com/ubi")
	not startswith(val, "registry.redhat.io/ubi")
	not startswith(val, "ghcr.io/nq-rdl/")
	val != "${BASE_CONTAINER}"
	msg := sprintf("Final FROM must use a UBI base or a UBI-rooted ghcr.io/nq-rdl/ base, got: %s", [val])
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `conftest verify --policy policy/`
Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add policy/base_image.rego policy/base_image_test.rego
git commit -m "policy(base): allow UBI-rooted ghcr.io/nq-rdl chained bases (\${BASE_CONTAINER})"
```

---

## Task 3: Trust `ghcr.io` in hadolint

**Files:**
- Modify: `.hadolint.yaml`

- [ ] **Step 1: Add ghcr.io to trustedRegistries**

In `.hadolint.yaml`, change the `trustedRegistries` list to:
```yaml
trustedRegistries:
  - registry.access.redhat.com
  - registry.redhat.io
  - ghcr.io
```

- [ ] **Step 2: Commit**

```bash
git add .hadolint.yaml
git commit -m "chore(hadolint): trust ghcr.io for chained repo-internal bases"
```

---

## Task 4: `docker-stacks-foundation-ubi9` image

**Files:**
- Create: `images/docker-stacks-foundation-ubi9/Containerfile`
- Create: `images/docker-stacks-foundation-ubi9/pixi.toml`
- Create: `images/docker-stacks-foundation-ubi9/pixi.lock` (generated)
- Create: `images/docker-stacks-foundation-ubi9/image.yaml`
- Create: `images/docker-stacks-foundation-ubi9/README.md`
- Create: `images/docker-stacks-foundation-ubi9/smoke-cmd`
- Create (vendored): `fix-permissions`, `_docker_stacks_log.sh`, `run-hooks.sh`, `start.sh`

- [ ] **Step 1: Vendor the upstream runtime scripts (verbatim, pinned SHA)**

```bash
mkdir -p images/docker-stacks-foundation-ubi9
SHA=96322b6b179e4de61eb6ddbbdadcd8fba61662f7
B="https://raw.githubusercontent.com/jupyter/docker-stacks/$SHA/images/docker-stacks-foundation"
for f in fix-permissions _docker_stacks_log.sh run-hooks.sh start.sh; do
  curl -fsSL "$B/$f" -o "images/docker-stacks-foundation-ubi9/$f"
done
chmod +x images/docker-stacks-foundation-ubi9/{fix-permissions,start.sh,run-hooks.sh}
```
Note: we deliberately do **not** vendor `initial-condarc` (pixi manages channels in
`pixi.toml`) or `10activate-conda-env.sh` (it runs `conda shell.bash hook`; pixi has no
`conda`, and `PATH` is set via `ENV`).

- [ ] **Step 2: Write `pixi.toml`**

Create `images/docker-stacks-foundation-ubi9/pixi.toml`:
```toml
[workspace]
name = "notebook-foundation"
channels = ["conda-forge"]
platforms = ["linux-64"]

[dependencies]
python = "3.12.*"
pip = "*"
jupyter_core = "*"
```

- [ ] **Step 3: Generate and inspect the lockfile**

Run (requires pixi locally; `make install-deps` installs it):
```bash
cd images/docker-stacks-foundation-ubi9 && pixi lock && cd -
test -f images/docker-stacks-foundation-ubi9/pixi.lock && echo "lock OK"
```
Expected: `pixi.lock` created; `lock OK`.

- [ ] **Step 4: Resolve the UBI9 base digest and tini checksum**

```bash
# UBI9 full base (re-verify; known-good from the StarRocks PR was 9.8):
skopeo inspect --no-tags docker://registry.access.redhat.com/ubi9/ubi:9.8 \
  | jq -r '.Digest'           # -> paste as @sha256:... in the Containerfile FROM
# tini static amd64 + its published checksum:
curl -fsSL -O https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-amd64
curl -fsSL https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-amd64.sha256sum
# pixi 0.47.0 binary checksum (record sha256 for the Containerfile):
curl -fsSL -O https://github.com/prefix-dev/pixi/releases/download/v0.47.0/pixi-x86_64-unknown-linux-musl.tar.gz
sha256sum pixi-x86_64-unknown-linux-musl.tar.gz
rm -f tini-static-amd64 pixi-x86_64-unknown-linux-musl.tar.gz
```
Record the three values (UBI digest, tini sha256, pixi sha256) for Step 5.

- [ ] **Step 5: Write the `Containerfile`** (substitute the three resolved checksums for `__…__`)

Create `images/docker-stacks-foundation-ubi9/Containerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
#
# docker-stacks-foundation on UBI9
# Blueprint: jupyter/docker-stacks@96322b6 images/docker-stacks-foundation/Dockerfile
# Changes: ubuntu:24.04 -> ubi9/ubi (digest-pinned); apt -> dnf; locale-gen dropped
#          (glibc C.UTF-8 built-in); micromamba+conda -> pixi (conda-forge) with a
#          committed pixi.lock; NB_GID 100 -> 0 (OpenShift arbitrary-UID model);
#          tini installed as a pinned static binary; conda-activate hook dropped (PATH-based).
#
FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:__UBI9_DIGEST__

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="0"
ARG PYTHON_VERSION=3.12
ARG PIXI_VERSION=0.47.0
ARG TINI_VERSION=0.19.0

LABEL org.opencontainers.image.title="docker-stacks-foundation-ubi9"
LABEL org.opencontainers.image.description="Jupyter docker-stacks-foundation on UBI9 (pixi/conda-forge)"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

# OS deps: sudo (start.sh root->user transition), shadow-utils (useradd), glibc-langpack-en
# (locales; C.UTF-8 is built into glibc so no locale-gen), ca-certificates, tar/gzip/bzip2,
# and wget for downloads. netbase is NOT needed (UBI 'setup' provides /etc/protocols etc.).
RUN dnf install -y --setopt=install_weak_deps=0 --nodocs \
        sudo shadow-utils glibc-langpack-en ca-certificates \
        tar gzip bzip2 wget which findutils \
    && dnf upgrade -y \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/yum

# tini (static) as a pinned binary; verify checksum.
RUN curl -fsSL -o /usr/bin/tini \
        "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-static-amd64" \
    && echo "__TINI_SHA256__  /usr/bin/tini" | sha256sum -c - \
    && chmod +x /usr/bin/tini

# pixi (static binary) as a pinned, checksum-verified install.
RUN curl -fsSL -o /tmp/pixi.tar.gz \
        "https://github.com/prefix-dev/pixi/releases/download/v${PIXI_VERSION}/pixi-x86_64-unknown-linux-musl.tar.gz" \
    && echo "__PIXI_SHA256__  /tmp/pixi.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/pixi.tar.gz -C /usr/local/bin pixi \
    && chmod +x /usr/local/bin/pixi \
    && rm -f /tmp/pixi.tar.gz

# pixi env prefix is exported as CONDA_DIR so the vendored start.sh (which derives PATH and
# sudo secure_path from ${CONDA_DIR}/bin) works unmodified.
ENV CONDA_DIR=/opt/nb/.pixi/envs/default \
    PIXI_PROJECT=/opt/nb \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Color prompt in skel (UBI skel differs from Ubuntu; add the line unconditionally).
RUN echo 'force_color_prompt=yes' >> /etc/skel/.bashrc

# Create the jovyan user with primary group 0 (root group) for arbitrary-UID tolerance.
# Block `su`; UBI sudoers uses %wheel (no %admin/%sudo), so comment %wheel to disable group sudo.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su \
    && sed -i.bak -e 's/^%wheel/#%wheel/' /etc/sudoers \
    && useradd --no-log-init --create-home --shell /bin/bash --uid "${NB_UID}" --gid "${NB_GID}" "${NB_USER}" \
    && mkdir -p "${PIXI_PROJECT}" \
    && chown "${NB_USER}:${NB_GID}" "${PIXI_PROJECT}" \
    && chmod g+w /etc/passwd \
    && fix-permissions "${PIXI_PROJECT}" \
    && fix-permissions "/home/${NB_USER}"

USER ${NB_UID}
WORKDIR /opt/nb

# Build the base conda-forge env from the committed lockfile (reproducible).
COPY --chown=${NB_UID}:${NB_GID} pixi.toml pixi.lock /opt/nb/
RUN pixi install --locked --manifest-path /opt/nb/pixi.toml \
    && pixi clean cache --yes || true \
    && fix-permissions "${PIXI_PROJECT}" \
    && fix-permissions "/home/${NB_USER}"

RUN mkdir -p "/home/${NB_USER}/work" && fix-permissions "/home/${NB_USER}"

# Runtime scripts (copied late to avoid cache busting).
COPY _docker_stacks_log.sh run-hooks.sh start.sh /usr/local/bin/
ENTRYPOINT ["tini", "-g", "--", "start.sh"]

USER root
RUN mkdir -p /usr/local/bin/start-notebook.d /usr/local/bin/before-notebook.d \
    && fix-permissions /usr/local/bin/start-notebook.d /usr/local/bin/before-notebook.d

USER ${NB_UID}
WORKDIR "${HOME}"
```

- [ ] **Step 6: Write `image.yaml`**

Create `images/docker-stacks-foundation-ubi9/image.yaml`:
```yaml
name: docker-stacks-foundation-ubi9
description: Jupyter docker-stacks-foundation on UBI9 (pixi/conda-forge)
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
  name: jupyter-foundation
tags:
  - "2026.6.0"
  - "2026.6"
  - "latest"
bake_target: foundation
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 7: Write `smoke-cmd` and `README.md`**

`images/docker-stacks-foundation-ubi9/smoke-cmd`:
```
python --version
```

`images/docker-stacks-foundation-ubi9/README.md`:
```markdown
# docker-stacks-foundation-ubi9

Jupyter `docker-stacks-foundation`, ported to UBI9 and built with **pixi** (conda-forge).
The root of the nq-rdl datascience-notebook chain.

- **Base:** `registry.access.redhat.com/ubi9/ubi` (digest-pinned)
- **Packages:** pixi-managed conda-forge env at `/opt/nb/.pixi/envs/default` (exported as `CONDA_DIR`)
- **User:** `jovyan` (UID 1000, **GID 0** — OpenShift arbitrary-UID friendly)
- **Entrypoint:** `tini -g -- start.sh` (upstream runtime contract)

Differs from upstream: Ubuntu→UBI9, micromamba/conda→pixi with a committed `pixi.lock`,
`NB_GID` 100→0. Not meant to be run directly; downstream images add the notebook server.
```

- [ ] **Step 8: Lint the Containerfile**

Run: `pixi run lint-containerfiles`
Expected: no errors for `docker-stacks-foundation-ubi9` (warnings threshold). If hadolint
flags `DL3059`/pinning, address per house style; the file mirrors existing UBI Containerfiles.

- [ ] **Step 9: Policy-check the image**

Run:
```bash
pixi run policy-check-containerfiles
pixi run policy-check-image-meta
```
Expected: PASS (final FROM is the UBI ref; tags match `X.Y.Z`/`X.Y`/`latest`).

- [ ] **Step 10: Build + smoke locally** (after substituting the three checksums)

```bash
docker build -t localhost/smoke/docker-stacks-foundation-ubi9:latest \
  images/docker-stacks-foundation-ubi9
docker run --rm localhost/smoke/docker-stacks-foundation-ubi9:latest python --version
# Arbitrary-UID check (OpenShift SCC simulation):
docker run --rm --user 4711:0 localhost/smoke/docker-stacks-foundation-ubi9:latest python --version
```
Expected: prints `Python 3.12.x` in both runs (the second proves the GID-0 arbitrary-UID model).

- [ ] **Step 11: Commit**

```bash
git add images/docker-stacks-foundation-ubi9
git commit -m "feat(docker-stacks-foundation-ubi9): Jupyter foundation on UBI9 via pixi (#30)"
```

---

## Task 5: Root `docker-bake.hcl` (foundation + base targets)

**Files:**
- Create: `docker-bake.hcl`

- [ ] **Step 1: Write `docker-bake.hcl`**

Create `docker-bake.hcl` at the repo root:
```hcl
variable "REGISTRY" { default = "ghcr.io/nq-rdl" }
variable "TAG"      { default = "2026.6.0" }

group "datascience" {
  targets = ["foundation", "base-notebook"]
}

target "foundation" {
  context    = "images/docker-stacks-foundation-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  tags = [
    "${REGISTRY}/docker-stacks-foundation-ubi9:${TAG}",
    "${REGISTRY}/docker-stacks-foundation-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=docker-stacks-foundation-ubi9"]
  cache-to   = ["type=gha,scope=docker-stacks-foundation-ubi9,mode=max"]
}

target "base-notebook" {
  context    = "images/base-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  # In-graph build: resolve FROM ${BASE_CONTAINER} to the just-built foundation target
  # instead of pulling from the registry.
  contexts = {
    "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9" = "target:foundation"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9"
  }
  tags = [
    "${REGISTRY}/base-notebook-ubi9:${TAG}",
    "${REGISTRY}/base-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=base-notebook-ubi9"]
  cache-to   = ["type=gha,scope=base-notebook-ubi9,mode=max"]
}
```

- [ ] **Step 2: Validate the bake file parses**

Run: `docker buildx bake --file docker-bake.hcl --print datascience`
Expected: prints the resolved JSON for both targets (no parse error). Requires
`docker buildx` (the repo already uses `docker/setup-buildx-action` in CI).

- [ ] **Step 3: Commit**

```bash
git add docker-bake.hcl
git commit -m "build(bake): add docker-bake.hcl wiring foundation -> base-notebook chain (#30)"
```

---

## Task 6: `base-notebook-ubi9` image (chained)

**Files:**
- Create: `images/base-notebook-ubi9/Containerfile`
- Create: `images/base-notebook-ubi9/pixi.toml`
- Create: `images/base-notebook-ubi9/pixi.lock` (generated)
- Create: `images/base-notebook-ubi9/image.yaml`
- Create: `images/base-notebook-ubi9/README.md`
- Create: `images/base-notebook-ubi9/smoke-cmd`
- Create (vendored): `start-notebook.py`, `start-notebook.sh`, `start-singleuser.py`, `start-singleuser.sh`, `jupyter_server_config.py`, `docker_healthcheck.py`

- [ ] **Step 1: Vendor the upstream base-notebook scripts (pinned SHA)**

```bash
mkdir -p images/base-notebook-ubi9
SHA=96322b6b179e4de61eb6ddbbdadcd8fba61662f7
B="https://raw.githubusercontent.com/jupyter/docker-stacks/$SHA/images/base-notebook"
for f in start-notebook.py start-notebook.sh start-singleuser.py start-singleuser.sh jupyter_server_config.py docker_healthcheck.py; do
  curl -fsSL "$B/$f" -o "images/base-notebook-ubi9/$f"
done
chmod +x images/base-notebook-ubi9/{start-notebook.py,start-notebook.sh,start-singleuser.py,start-singleuser.sh,docker_healthcheck.py}
```

- [ ] **Step 2: Write `pixi.toml`** (full cumulative env — foundation deps + this layer)

Create `images/base-notebook-ubi9/pixi.toml`:
```toml
[workspace]
name = "base-notebook"
channels = ["conda-forge"]
platforms = ["linux-64"]

[dependencies]
python = "3.12.*"
pip = "*"
jupyter_core = "*"
jupyterhub-singleuser = "*"
jupyterlab = "*"
nbclassic = "*"
notebook = ">=7.2.2"
```

- [ ] **Step 3: Generate the lockfile**

```bash
cd images/base-notebook-ubi9 && pixi lock && cd -
test -f images/base-notebook-ubi9/pixi.lock && echo "lock OK"
```
Expected: `pixi.lock` created.

- [ ] **Step 4: Resolve the foundation base digest and pandoc checksum**

The foundation image must be built/pushed first to get its digest. For local development use
the digest of the locally-built image; for the committed default use the pushed digest after
Task 4 merges. Resolve:
```bash
# Foundation digest (after `docker build` in Task 4, or `skopeo inspect` of the pushed image):
docker images --no-trunc --quiet localhost/smoke/docker-stacks-foundation-ubi9:latest
# pandoc 3.10 amd64 tarball checksum:
curl -fsSL -O https://github.com/jgm/pandoc/releases/download/3.10/pandoc-3.10-linux-amd64.tar.gz
sha256sum pandoc-3.10-linux-amd64.tar.gz && rm -f pandoc-3.10-linux-amd64.tar.gz
```
Note: the `ARG BASE_CONTAINER` default below MUST be a real pushed
`ghcr.io/nq-rdl/...@sha256:` digest before merge (enforced by
`tests/test-chained-bases-pinned.sh`). For local bake builds the digest is overridden by the
`contexts` wiring in `docker-bake.hcl`, so a placeholder-but-well-formed pin builds locally.

- [ ] **Step 5: Write the `Containerfile`**

Create `images/base-notebook-ubi9/Containerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
#
# base-notebook on UBI9 (chained on docker-stacks-foundation-ubi9)
# Blueprint: jupyter/docker-stacks@96322b6 images/base-notebook/Dockerfile
# Changes: BASE_IMAGE -> ${BASE_CONTAINER} (repo-internal UBI-rooted base); apt -> dnf;
#          fonts-liberation -> liberation-fonts; pandoc apt -> pinned static binary;
#          run-one dropped (no RESTARTABLE); mamba install -> pixi install --locked.
#
ARG BASE_CONTAINER=ghcr.io/nq-rdl/docker-stacks-foundation-ubi9:2026.6.0@sha256:__FOUNDATION_DIGEST__
FROM ${BASE_CONTAINER}

ARG PANDOC_VERSION=3.10

LABEL org.opencontainers.image.title="base-notebook-ubi9"
LABEL org.opencontainers.image.description="Jupyter base-notebook (JupyterLab + Notebook + Hub single-user) on UBI9"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

# Fonts for matplotlib/seaborn. pandoc (for nbconvert -> html/pdf) as a pinned static binary
# (not in UBI BaseOS/AppStream). run-one is intentionally dropped (RESTARTABLE unsupported).
RUN dnf install -y --setopt=install_weak_deps=0 --nodocs liberation-fonts \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/yum
RUN curl -fsSL -o /tmp/pandoc.tar.gz \
        "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz" \
    && echo "__PANDOC_SHA256__  /tmp/pandoc.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/pandoc.tar.gz -C /usr/local --strip-components=1 \
        "pandoc-${PANDOC_VERSION}/bin/pandoc" \
    && rm -f /tmp/pandoc.tar.gz \
    && pandoc --version

USER ${NB_UID}

# Add the Jupyter server stack to the inherited pixi env, from the committed lockfile.
COPY --chown=${NB_UID}:${NB_GID} pixi.toml pixi.lock /opt/nb/
RUN pixi install --locked --manifest-path /opt/nb/pixi.toml \
    && jupyter server --generate-config \
    && jupyter lab clean \
    && pixi clean cache --yes || true \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "/home/${NB_USER}"

ENV JUPYTER_PORT=8888
EXPOSE $JUPYTER_PORT
CMD ["start-notebook.py"]

COPY start-notebook.py start-notebook.sh start-singleuser.py start-singleuser.sh /usr/local/bin/
COPY jupyter_server_config.py docker_healthcheck.py /etc/jupyter/

USER root
RUN fix-permissions /etc/jupyter/

HEALTHCHECK --interval=3s --timeout=1s --start-period=3s --retries=3 \
    CMD /etc/jupyter/docker_healthcheck.py || exit 1

USER ${NB_UID}
WORKDIR "${HOME}"
```

- [ ] **Step 6: Write `image.yaml`**

Create `images/base-notebook-ubi9/image.yaml`:
```yaml
name: base-notebook-ubi9
description: Jupyter base-notebook on UBI9 (JupyterLab + Notebook + Hub single-user)
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: ghcr.io
  repository: nq-rdl/docker-stacks-foundation-ubi9
  version: "2026.6.0"
runtime:
  name: jupyter-base-notebook
tags:
  - "2026.6.0"
  - "2026.6"
  - "latest"
depends_on: docker-stacks-foundation-ubi9
bake_target: base-notebook
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 7: Write `smoke-cmd` and `README.md`**

`images/base-notebook-ubi9/smoke-cmd`:
```
jupyter --version
```

`images/base-notebook-ubi9/README.md`:
```markdown
# base-notebook-ubi9

Jupyter `base-notebook` on UBI9: JupyterLab, Notebook (>=7.2.2), NBClassic, and
JupyterHub single-user — chained on `docker-stacks-foundation-ubi9`.

- **Base:** `ghcr.io/nq-rdl/docker-stacks-foundation-ubi9` (digest-pinned, UBI-rooted)
- **Server:** `start-notebook.py` (`CMD`); `start-singleuser.py` for JupyterHub
- **Port:** 8888 (`EXPOSE`); `HEALTHCHECK` via `docker_healthcheck.py`
- **User:** `jovyan` (UID 1000, GID 0)

Dropped vs upstream: `run-one`/`RESTARTABLE` (rarely used; no RPM). `pandoc` is a pinned
static binary; fonts via `liberation-fonts`.
```

- [ ] **Step 8: Lint + policy-check**

```bash
pixi run lint-containerfiles
pixi run policy-check-containerfiles
pixi run policy-check-image-meta
pixi run policy-check-chained-bases   # validates the ARG BASE_CONTAINER pin
```
Expected: PASS. (`policy-check-chained-bases` requires the `ARG BASE_CONTAINER` default to be
a well-formed `ghcr.io/nq-rdl/...@sha256:` ref.)

- [ ] **Step 9: Build the chain via bake + smoke**

```bash
docker buildx bake --file docker-bake.hcl --load base-notebook
docker run --rm ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0 jupyter --version
docker run --rm ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0 \
  bash -lc "jupyter lab --version && python -c 'import jupyterhub'"
# Healthcheck/server smoke (start a server, curl /api, stop):
cid=$(docker run -d -p 8888:8888 ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0 \
       start-notebook.py --IdentityProvider.token=smoke)
sleep 8 && curl -fsSL "http://localhost:8888/api" && echo " <- server OK"
docker logs "$cid" | tail -5; docker rm -f "$cid"
```
Expected: `jupyter --version` lists components; `/api` returns JSON `{"version": ...}`.
`bake … base-notebook` builds `foundation` first (via `contexts`) with no registry pull.

- [ ] **Step 10: Commit**

```bash
git add images/base-notebook-ubi9
git commit -m "feat(base-notebook-ubi9): Jupyter base-notebook on UBI9, chained on foundation (#30)"
```

---

## Task 7: CI — add a bake job for chained images

**Files:**
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1: Exclude `bake_target` images from the per-image matrix**

In `build.yml`'s `discover` job `set-matrix` step, after collecting `DIRS`, drop directories
whose `image.yaml` declares `bake_target:` (they are built by the new `bake` job). Add this
filter right before the matrix-building loop:
```bash
          # Exclude images built by docker-bake (the chained Jupyter stack).
          DIRS=$(while IFS= read -r d; do
                   [ -z "$d" ] && continue
                   if [ -f "images/${d}/image.yaml" ] && yq -e '.bake_target' "images/${d}/image.yaml" >/dev/null 2>&1; then
                     continue
                   fi
                   echo "$d"
                 done <<< "$DIRS")
```

- [ ] **Step 2: Add the `bake` job**

Add a new job to `build.yml` (after `build`), mirroring the existing auth/scan steps but
driving `docker buildx bake`:
```yaml
  bake:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: docker/setup-qemu-action@v4
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Bake the datascience chain
        env:
          REGISTRY: ghcr.io/${{ github.repository_owner }}
          TAG: "2026.6.0"
        run: |
          set -euo pipefail
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            docker buildx bake --file docker-bake.hcl --load datascience
          else
            docker buildx bake --file docker-bake.hcl --push datascience
          fi

      - name: Trivy scan (foundation + base-notebook)
        run: |
          set -euo pipefail
          for img in docker-stacks-foundation-ubi9 base-notebook-ubi9; do
            ref="ghcr.io/${{ github.repository_owner }}/${img}:2026.6.0"
            trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 0 \
              --format sarif --output "trivy-${img}.sarif" "$ref" || true
          done

      - name: Upload Trivy results
        if: always()
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: .
          category: trivy-bake
```
Note: keep the existing `provenance`/`sbom`/attestation pattern if desired; for Phase 1 the
Trivy gate + push is the minimum. (A follow-up can add per-image attestation by iterating the
two images like the matrix `build` job does.)

- [ ] **Step 3: Lint the workflow**

Run: `pixi run lint-actions`
Expected: actionlint passes.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(build): bake the datascience chain; exclude bake_target images from the matrix (#30)"
```

---

## Task 8: Local smoke + Trivy honor the bake chain

**Files:**
- Modify: `scripts/smoke-test.sh`
- Modify: `scripts/trivy-scan.sh`

- [ ] **Step 1: Build chained images via bake in `smoke-test.sh`**

In `scripts/smoke-test.sh` Phase 1 (build loop), skip directories with a `bake_target` and
build them once via bake before the loop. After computing `CONTAINERFILES`, add:
```bash
# Build bake_target (chained) images via docker buildx bake; map their tags into BUILT.
BAKE_IMAGES=()
if [ "$RUNTIME" = "docker" ] && command -v docker >/dev/null && docker buildx version >/dev/null 2>&1; then
  mapfile -t BAKE_DIRS < <(grep -lR --include=image.yaml 'bake_target:' "$IMAGES_DIR" | xargs -r -n1 dirname)
  if [ "${#BAKE_DIRS[@]}" -gt 0 ]; then
    echo "==> Baking chained images: ${BAKE_DIRS[*]}"
    docker buildx bake --file "${REPO_ROOT}/docker-bake.hcl" --load datascience
    for d in "${BAKE_DIRS[@]}"; do
      name=$(basename "$d")
      tag="ghcr.io/nq-rdl/${name}:2026.6.0"
      BAKE_IMAGES+=("$d")
      BUILT+=("${tag}|${name}|${d}")
    done
  fi
fi
```
And in the per-Containerfile build loop, skip bake images:
```bash
  if printf '%s\n' "${BAKE_IMAGES[@]:-}" | grep -qx "$dir"; then continue; fi
```
(podman has no `buildx bake`; when `RUNTIME=podman`, fall back to building each chained
Containerfile with a `--build-arg BASE_CONTAINER=<locally-built parent tag>` in dependency
order — foundation before base-notebook. Document this in a comment.)

- [ ] **Step 2: Mirror the skip in `trivy-scan.sh`**

In `scripts/trivy-scan.sh`, reuse images from the smoke build cache as today; ensure the
bake-built tags (`ghcr.io/nq-rdl/<name>:2026.6.0`) are scanned. If `trivy-scan.sh` rebuilds,
add the same bake invocation guard so chained images aren't built standalone (which would fail
on the unresolved `${BASE_CONTAINER}`).

- [ ] **Step 3: Run the full local smoke**

Run: `scripts/smoke-test.sh`
Expected: foundation + base-notebook build via bake, run their `smoke-cmd`, and start as k3d
pods reaching Succeeded/Running. All other images still build via the normal loop.

- [ ] **Step 4: Shellcheck + commit**

```bash
pixi run lint-shell
git add scripts/smoke-test.sh scripts/trivy-scan.sh
git commit -m "test(smoke): build chained Jupyter images via docker buildx bake (#30)"
```

---

## Task 9: Changelog + full green gate

**Files:**
- Create: `.changes/unreleased/Added-<timestamp>.yaml`

- [ ] **Step 1: Add a changie fragment**

Run:
```bash
changie new --kind Added \
  --body "Add UBI9 Jupyter foundation + base-notebook images (pixi/conda-forge) built with docker buildx bake (#30, phase 1)."
```
(or create `.changes/unreleased/Added-<ts>.yaml` with `kind: Added` and that `body:`.)

- [ ] **Step 2: Run the full local gate**

```bash
pixi run lint-all
pixi run policy-check
scripts/smoke-test.sh
scripts/trivy-scan.sh
```
Expected: all green. Trivy must report no **fixable** CRITICAL/HIGH (the local hook blocks on
those); `dnf upgrade -y` in foundation mitigates OS-layer findings, and conda-forge packages
are scanned with `--ignore-unfixed`.

- [ ] **Step 3: Commit + open the Phase-1 PR**

```bash
git add .changes/unreleased/
git commit -m "docs(changelog): datascience-notebook UBI9 phase 1 fragment (#30)"
git push -u origin feat/datascience-notebook-ubi9
gh pr create --base main --title "feat: UBI9 Jupyter foundation + base-notebook via pixi + bake (#30, phase 1)" \
  --body "Phase 1 of the datascience-notebook UBI9 stack (spec: docs/superpowers/specs/2026-06-06-datascience-notebook-ubi9-design.md). Adds the foundation + base-notebook images, docker-bake.hcl chaining, and the policy/CI enablement. Closes part of #30."
```
Expected: CI `Build Images` runs the new `bake` job (`--load` on PR) + Trivy; `Validate Base
Pins`, `policy`, `lint`, `hadolint` all green.

---

## Self-review notes (author)

- **Spec coverage:** §3 (mechanism+packages) → Tasks 4–6; §6 bake → Task 5/7/8; §7 policy
  reconciliation → Tasks 1–3; §8 user model → Task 4 (GID 0 + arbitrary-UID smoke in Step 10);
  §9 runtime contract → vendored scripts (Tasks 4,6); §10 versioning → `image.yaml` tags;
  §12 smoke → `smoke-cmd` + Task 6 Step 9; §13 compliance → Tasks 1–3, 8, 9.
- **Deferred to later phases (not Phase 1):** minimal/scipy/datascience images, TeX/ffmpeg/R/
  Julia, multi-image attestation parity in the bake job.
- **Known exec-time resolutions (not placeholders — explicit procedures):** UBI9 digest,
  tini/pixi/pandoc sha256 (Task 4 Step 4, Task 6 Step 4), foundation digest for the
  `ARG BASE_CONTAINER` default (Task 6 Step 4), generated `pixi.lock` files (`pixi lock`).
- **Risk to watch first:** `pixi install --locked` into `${CONDA_DIR}` as USER 1000 with
  `/opt/nb` group-0-owned, and `run-hooks.sh` over an empty `before-notebook.d` — both
  exercised by Task 4 Step 10 / Task 6 Step 9 before anything builds on them.
```
