# Datascience-notebook UBI9 stack + BuildKit

- **Date:** 2026-06-06
- **Status:** Implemented (Phase 1) — foundation + base-notebook shipped; the GID-0 user model was validated empirically (arbitrary-UID smoke passed) during implementation
- **Branch:** `feat/datascience-notebook-ubi9`
- **Closes:** Issue #30 (*Feat: Buildkit*) — and delivers the `/goal`: UBI9 images for the
  `datascience-notebook` stack and its upstream lineage, built with BuildKit.

## 1. Problem

Issue #30 asks us to bring **BuildKit** and **hermetic multi-stage builds** into our
process, citing the [jupyter/docker-stacks](https://github.com/jupyter/docker-stacks)
`Makefile` and the `datascience-notebook` `Dockerfile`. The `/goal` makes the concrete
deliverable explicit: **UBI9 ports of the `datascience-notebook` image and every upstream
image in its lineage, built with BuildKit**, following this repo's rules (UBI base,
`Containerfile`, OCI labels, digest pins, Trivy gating, smoke tests).

Three facts shape the whole design:

1. **The stack is a five-image `FROM`-chain.** Upstream lineage:
   `docker-stacks-foundation → base-notebook → minimal-notebook → scipy-notebook →
   datascience-notebook`. Upstream expresses the chain with a `BASE_IMAGE`/`BASE_CONTAINER`
   build-arg (`FROM $BASE_IMAGE`), **one Dockerfile per image** — not a single multi-stage
   file. BuildKit is enabled simply via `DOCKER_BUILDKIT=1 docker build`.
2. **BuildKit is already in our CI** (`build.yml` uses `docker/setup-buildx-action` +
   `docker/build-push-action` with `cache-from/to: type=gha`, and every `Containerfile`
   carries `# syntax=docker/dockerfile:1.7`). The genuine gaps issue #30 points at are
   **layered chaining**, **artifact reuse across images**, and **parallelism** — plus a
   reconciliation with our "every image is `FROM` UBI" policy.
3. **The hard parts of the stack have no clean UBI/EPEL path.** R + ~20 `r-*` packages,
   Julia, `ffmpeg`, `dvipng`/`cm-super`, and TeX Live are painful or impossible to assemble
   from RPMs — but all are first-class on **conda-forge**, which **pixi** (already this
   repo's tooling backbone) resolves with a committed lockfile.

So the value: **the real datascience-notebook stack, repackaged onto pinned, Trivy-scanned,
attested UBI9 bases, reproducibly built with `pixi.lock` + `docker buildx bake`**, chained
exactly like upstream but UBI-rooted and policy-compliant.

## 2. Goals / Non-goals

**Goals**

- Five chained images under `images/`, upstream-mirror names with the mandatory `-ubi9`
  suffix:
  `docker-stacks-foundation-ubi9`, `base-notebook-ubi9`, `minimal-notebook-ubi9`,
  `scipy-notebook-ubi9`, `datascience-notebook-ubi9`.
- Package management via **pixi (conda-forge)** with a committed `pixi.toml` + `pixi.lock`
  per image (reproducibility upstream lacks).
- **BuildKit chaining via a root `docker-bake.hcl`** (`contexts = target:<parent>`) — the
  concrete realization of issue #30 (hermetic multi-stage, artifact reuse, parallel siblings,
  `--load` PR builds, `type=gha` cache).
- **JupyterHub / Kubernetes-ready** runtime: faithful port of `start.sh`,
  `start-notebook.py`, `start-singleuser.py`, `docker_healthcheck.py`, `fix-permissions`,
  `EXPOSE 8888`, `HEALTHCHECK`.
- `linux/amd64` only (matches every existing repo image).
- Pass all repo policies/lints (base policy, pin tests, labels, tag patterns, hadolint) and
  the smoke-test harness.
- One changie fragment per phase (kind **Added**).

**Non-goals**

- `linux/arm64` (deferred to a follow-up once the amd64 port is validated).
- A multi-`PYTHON_VERSION` build matrix (v1 pins a single Python; see §10).
- Sibling stacks not in the datascience lineage (`r-notebook`, `julia-notebook`,
  `tensorflow`, `pytorch`, `pyspark`, GPU/CUDA variants).
- Building any conda/R/Julia package **from source** (use conda-forge prebuilt binaries).
- Re-architecting the *existing* repo images onto bake — they stay on the current per-image
  path; bake is introduced **for the new chain** and available to others later.
- Shipping JupyterHub/k8s deployment manifests (the images are drop-in; deployment is the
  consumer's concern).
- `run-one` / `RESTARTABLE` and host-clipboard `xclip` (dropped — see §5; documented in
  READMEs).

## 3. Approaches considered

**Build mechanism (issue #30)** — *chosen by the user:*

| # | Approach | Verdict |
|---|----------|---------|
| A | **Per-image `Containerfile` (`FROM ${BASE_CONTAINER}`) + root `docker-bake.hcl`** wiring the DAG via BuildKit `contexts` | **Chosen.** Keeps the repo's per-directory layout; BuildKit handles ordering, parallel siblings, `--load` PR builds, `gha` cache; smallest policy blast radius (§7). |
| B | Single multi-stage `Containerfile` with named targets | Rejected — ~500-line file; breaks `images/<name>/` layout and independent versioning; rebuilds the whole graph on any change. |
| C | Per-image, ordered by the CI matrix/`needs` graph, no bake | Rejected — local smoke needs a retag/ordering shim and PR builds must push intermediates; bake gives ordering + local chaining for free. |

**Package strategy** — *chosen by the user (pixi):*

| # | Approach | Verdict |
|---|----------|---------|
| A | **pixi (conda-forge + PyPI) with committed `pixi.lock`** | **Chosen.** conda-forge supplies R, Julia, ffmpeg, TeX, the full SciPy stack as prebuilt binaries; pixi is already the repo's toolchain and yields a reviewable lockfile. |
| B | UBI/EPEL RPM + pip only | Rejected — `r-tidyverse`/`r-tidymodels`/`rpy2`, ffmpeg, cm-super have no UBI-accessible RPM; compiling from source is a maintenance + Trivy-surface nightmare. |
| C | Hybrid (system Python + pip; conda only for R/Julia) | Rejected — two package managers and two lockfile systems to keep coherent. |

## 4. Image set

Five directories under `images/`, each with `Containerfile`, `image.yaml`, `README.md`,
`smoke-cmd`, `pixi.toml`, `pixi.lock`, and any vendored scripts. The chain (each `FROM`s the
prior `ghcr.io/nq-rdl/...-ubi9` image, digest-pinned via `ARG BASE_CONTAINER`):

| Directory | Role / adds | Bake target |
|-----------|-------------|-------------|
| `docker-stacks-foundation-ubi9` | UBI9 (full) base + locales + `tini` + `sudo`; **pixi** bootstrap → conda-forge Python in a pixi env; `jovyan` user; `start.sh` entrypoint | `foundation` |
| `base-notebook-ubi9` | JupyterLab + notebook + `jupyterhub-singleuser`; `start-notebook.py` CMD; server config; `HEALTHCHECK`; `pandoc` (binary) + liberation fonts | `base-notebook` |
| `minimal-notebook-ubi9` | git/curl/vim-minimal/openssh-clients/tzdata/less; **TeX Live via conda-forge**; `Rprofile.site`; `/opt/setup-scripts/` | `minimal-notebook` |
| `scipy-notebook-ubi9` | full SciPy stack via conda-forge (numpy/scipy/pandas/scikit-learn/matplotlib/bokeh/dask/numba…); `gcc gcc-c++ make`; ffmpeg/dvipng/cm-super via conda-forge | `scipy-notebook` |
| `datascience-notebook-ubi9` | R (`r-base` + `r-*` + `rpy2`) via conda-forge; **Julia via conda-forge**; `gcc-gfortran` + dejavu fonts | `datascience-notebook` |

`foundation` is the only image whose final `FROM` is a UBI registry ref; the other four chain
on the prior repo image.

## 5. Package strategy — pixi per layer

Each image carries a committed **`pixi.toml`** (the conda-forge / PyPI packages *that layer
adds*) and a **`pixi.lock`**. The `Containerfile` does:

```dockerfile
COPY pixi.toml pixi.lock /opt/nb/
RUN pixi install --locked --manifest-path /opt/nb/pixi.toml
```

The pixi-managed env prefix is exported as `CONDA_DIR` (so ported upstream scripts/configs
that reference `${CONDA_DIR}` resolve unchanged) and `${CONDA_DIR}/bin` is on `PATH`.
Because each child inherits the parent's filesystem (pixi env + lock) via the `FROM` chain,
`pixi install --locked` on a child **adds** that layer's packages to the existing env. The
committed lock makes every layer's contents deterministic → **stable Trivy reports** and
reproducible rebuilds (this is strictly better than upstream, which does not lock at all).

**"Can pixi do Julia?"** — yes: conda-forge ships `julia`, so `pixi add julia` puts it in the
lockfile. (Upstream downloads the official Julia tarball; conda-forge is chosen here for
lockfile coverage. If version currency ever matters, the official-tarball path via
`/opt/setup-scripts/setup_julia.py` remains a documented fallback.)

**Base OS layer (thin).** Full `registry.access.redhat.com/ubi9/ubi` (not `ubi-minimal`) for
`dnf` + broader BaseOS; the OS package set shrinks to what conda-forge can't supply:

| Upstream (apt) | UBI9 |
|---|---|
| `locales` + `locale-gen` | `glibc-langpack-en` (drop `locale-gen`; set `LANG`/`LC_ALL`/`LANGUAGE` directly) |
| `tini` | static binary from `krallin/tini` releases (pinned ver + sha256 → `/usr/bin/tini`) |
| `pandoc` | static binary from `jgm/pandoc` releases (pinned ver + sha256) |
| `fonts-liberation` | `liberation-mono-fonts` + `liberation-fonts-common` (RPM; UBI9 has no sans/serif RPM) + the `fonts-conda-forge` meta-package (note: `font-ttf-liberation` does **not** exist on conda-forge) |
| `fonts-dejavu` | `dejavu-*-fonts` (BaseOS/AppStream) |
| `vim-tiny` / `nano-tiny` | `vim-minimal` / `nano` (drop `update-alternatives`) |
| `openssh-client` | `openssh-clients` |
| `build-essential` | `gcc gcc-c++ make` (+ `gcc-gfortran` at datascience) |
| `bzip2`,`ca-certificates`,`sudo`,`wget`,`git`,`curl`,`tzdata`,`less`,`unzip` | 1:1 in BaseOS/AppStream |
| `texlive-*`, `ffmpeg`, `dvipng`, `cm-super`, R, Julia, SciPy stack | **conda-forge (pixi)** |

**Deliberately dropped** (documented in READMEs): `run-one`/`RESTARTABLE` (rarely used; no
RPM) and `xclip` (host-clipboard X tool, irrelevant in a headless container). Dropping both
means **no EPEL dependency** at any layer.

**Debian→UBI re-implementations:** `apt-get` → `dnf … --setopt=install_weak_deps=0 --nodocs`
+ `dnf clean all`; drop `DEBIAN_FRONTEND`; sudoers `%sudo`/`%admin` sed → `%wheel` (or a
locked-down `/etc/sudoers.d/` drop-in); `groupadd --gid 0`-aware `fix-permissions` (see §8);
`/etc/skel/.bashrc` color-prompt line added unconditionally (UBI skel differs).

## 6. Build system — BuildKit via `docker-bake.hcl`

A new **`docker-bake.hcl`** at the repo root expresses the DAG. Children declare a named
context bound to the parent **target**, so an in-graph build uses the just-built parent (no
registry round-trip); standalone builds fall back to the digest-pinned `ARG` default.

```hcl
variable "REGISTRY" { default = "ghcr.io/nq-rdl" }
variable "TAG"      { default = "2026.6.0" }

group "datascience" {
  targets = ["foundation", "base-notebook", "minimal-notebook", "scipy-notebook", "datascience-notebook"]
}

target "foundation" {
  context = "images/docker-stacks-foundation-ubi9"
  tags    = ["${REGISTRY}/docker-stacks-foundation-ubi9:${TAG}"]
  cache-from = ["type=gha,scope=foundation"]
  cache-to   = ["type=gha,scope=foundation,mode=max"]
}

target "base-notebook" {
  context  = "images/base-notebook-ubi9"
  contexts = { "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9" = "target:foundation" }
  args     = { BASE_CONTAINER = "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9" }
  tags     = ["${REGISTRY}/base-notebook-ubi9:${TAG}"]
  cache-from = ["type=gha,scope=base-notebook"]
  cache-to   = ["type=gha,scope=base-notebook,mode=max"]
}
# … minimal-notebook, scipy-notebook, datascience-notebook chain identically
```

Each child `Containerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_CONTAINER=ghcr.io/nq-rdl/<parent>-ubi9:2026.6.0@sha256:<digest>
FROM ${BASE_CONTAINER}
```

Bake passes the **tagless** image name as a `BASE_CONTAINER` build-arg override **and**
simultaneously registers a named `context` under that same tagless key pointing to
`target:<parent>`. Both halves are required together: `args` makes BuildKit resolve a tagless
`FROM`, and `contexts` maps that ref to the in-graph target (matched after BuildKit's
`TrimSuffix(":latest")` normalization). Omitting either half silently falls back to a registry
pull. For a standalone `docker build` (no bake) the digest-pinned `ARG` default pulls the
published parent.

**`.github/workflows/build.yml`** — the `discover` job excludes images carrying
`bake_target:` from the per-image matrix (existing images keep the current path). A new job
runs `docker buildx bake --file docker-bake.hcl datascience` with `--load` on PRs and
`--push` on `main`/dispatch, then runs the existing Trivy scan per resulting image
(provenance/SBOM attestation for the bake images is deferred to Phase 2). On `main`, a
follow-up step mints the suffix-less convenience aliases (`docker-stacks-foundation`,
`base-notebook`). `type=gha` cache + parallel sibling builds give the issue's
"parallel … for optimal speed."

**`scripts/smoke-test.sh` / `scripts/trivy-scan.sh`** — for the chain, invoke
`docker buildx bake --file docker-bake.hcl --load` once (bake's `contexts` feed each child its
parent from the local build cache, eliminating the retag shim). Standalone images keep the
existing per-`Containerfile` `"$RUNTIME" build` loop; the loop skips any directory whose
`image.yaml` has `bake_target:`.

**`image.yaml`** gains two fields consumed by the discover/smoke logic:

```yaml
depends_on: docker-stacks-foundation-ubi9   # parent image dir; absent for foundation
bake_target: base-notebook                  # key in docker-bake.hcl
```

## 7. Chaining ↔ policy reconciliation (the crux)

The repo guarantees "every image is UBI-rooted." A chained `FROM` must preserve that
**transitively**: a `ghcr.io/nq-rdl/*` image is only ever pushed after passing this same
policy, so any child chaining on it is UBI-rooted by construction. Concretely, the
`ARG BASE_CONTAINER` + `FROM ${BASE_CONTAINER}` idiom interacts with the existing guards as
follows:

| Guard | Behaviour on `FROM ${BASE_CONTAINER}` | Change needed |
|---|---|---|
| `policy/base_image.rego` | final-stage `FROM` value is the literal `${BASE_CONTAINER}` → fails the UBI-prefix check | **Yes** — accept the `${BASE_CONTAINER}` sentinel (and/or `ghcr.io/nq-rdl/` prefix), with the transitive-UBI invariant documented. Foundation still asserts a UBI ref. |
| `tests/test-base-images-pinned.sh` | `${BASE_CONTAINER}` has no `/`,`.`,`:`,`@` → treated as an exempt **stage ref** | None (but the `ARG` default's digest is then unvalidated → new guard below) |
| `.github/workflows/validate-base-pins.yml` | only processes `FROM`s containing `@sha256:`; `${BASE_CONTAINER}` is skipped | None |
| `.github/workflows/base-drift.yml` | greps `^FROM` for `@sha256:`; the `ARG`-line digest is ignored, `${BASE_CONTAINER}` skipped | None (internal bases are re-pinned by our own rebuilds, not the upstream drift watcher — correct) |
| `.hadolint.yaml` | DL3026 may flag the `ghcr.io` default | **Yes** — add `ghcr.io` to `trustedRegistries` |

New guard **`tests/test-chained-bases-pinned.sh`** (wired into `pixi run policy-check`):
assert every `ARG BASE_CONTAINER=` default is a `ghcr.io/nq-rdl/<name>-ubi9:<tag>@sha256:<digest>`
ref — restoring the digest-pin guarantee that the stage-ref exemption would otherwise drop.

`base_image.rego` edit (illustrative):

```rego
# Repo-internal images under ghcr.io/nq-rdl/ are UBI-rooted by construction: each must
# pass this policy before being pushed, so a chained FROM is transitively UBI-rooted.
# The chain is expressed as `ARG BASE_CONTAINER=ghcr.io/nq-rdl/...@sha256:...` + `FROM ${BASE_CONTAINER}`;
# the ARG default's digest pin is enforced by tests/test-chained-bases-pinned.sh.
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

## 8. User / permission model

**Decision (validated in Phase 1):** keep upstream's identity but adopt this repo's
arbitrary-UID posture — **`NB_USER=jovyan`, `NB_UID=1000`, `NB_GID=0`** (primary group
root), with `fix-permissions` run against **GID 0**. Rationale:

- JupyterHub/k8s configs, docs, and volume mounts that assume the `jovyan` user and
  `/home/jovyan` keep working (upstream fidelity).
- GID-0-writable trees + group-writable `/etc/passwd` make the image tolerate a random
  runtime UID under OpenShift's restricted SCC — matching `images/python-ubi9/Containerfile`'s
  `-g 0` convention rather than upstream's GID-100 (`users`) group.
- `NB_GID` stays an `ARG`/`ENV` (default `0`) so the GID-100 upstream behaviour is still
  reachable if needed.

Pitfalls to verify in Phase 1: GID 100 (`users`) already exists on UBI9 (we use 0, so moot);
pixi/conda env files must be group-0 readable/writable after `fix-permissions`; the
`/etc/passwd` group-write + `start.sh` self-registration of the arbitrary UID works on UBI9.
This decision was **validated empirically during Phase 1**: foundation and base-notebook run
correctly under an arbitrary runtime UID (`--user 4711:0`) — `start.sh` self-registers the UID
into the group-0-writable `/etc/passwd`. (A Codex second opinion was requested but the job hung
and was cancelled; the empirical smoke is the stronger evidence anyway.)

## 9. Runtime contract (JupyterHub / k8s-ready)

Faithful, OS-agnostic port (copied largely verbatim — all bash/Python):
`fix-permissions`, `_docker_stacks_log.sh`, `run-hooks.sh`, `start.sh`,
`before-notebook.d/10activate-conda-env.sh` (dropped — it runs `conda shell.bash hook`; pixi
ships no `conda`, and `${CONDA_DIR}/bin` is on `PATH` via `ENV`, so PATH-based activation
suffices; `conda activate` is unavailable),
`initial-condarc` (pixi-equivalent channel config), `start-notebook.py`,
`start-singleuser.py`, `jupyter_server_config.py`, `docker_healthcheck.py`.
`ENTRYPOINT ["tini","-g","--","start.sh"]`; `CMD ["start-notebook.py"]` at base-notebook;
`ENV JUPYTER_PORT=8888`; `EXPOSE 8888`; `HEALTHCHECK … docker_healthcheck.py`.

## 10. Versioning & tags

No upstream semver exists for the stack, and `policy/image-meta/tags.rego` permits only
`X.Y.Z`, `X.Y`, `latest`. Adopt a **CalVer stack release line** shared by all five images:
`tags: ["2026.6.0", "2026.6", "latest"]`. A single pinned **`PYTHON_VERSION=3.12`** ARG for
v1 (chosen for broad conda-forge R/`rpy2`/scientific coverage; revisit a `PYTHON_VERSION`
matrix later). No `build_matrix` in v1. `publish-aliases` then mints the suffix-less
`datascience-notebook` (etc.) convenience aliases automatically.

## 11. `image.yaml` pattern (per directory)

```yaml
name: base-notebook-ubi9
description: Jupyter base-notebook on UBI9
owners: [nq-rdl/platform, nq-rdl/data-engineering]
platforms: [linux/amd64]
base: { registry: ghcr.io, repository: nq-rdl/docker-stacks-foundation-ubi9, version: "2026.6.0" }
runtime: { name: jupyter-base-notebook }
tags: ["2026.6.0", "2026.6", "latest"]
depends_on: docker-stacks-foundation-ubi9
bake_target: base-notebook
support: { status: stable, eol: "2027-06-30" }
```

(`foundation` omits `depends_on`/`bake_target`'s parent and sets `base:` to the UBI ref.)

## 12. Smoke tests

Notebook servers are long-running, but the harness needs a fast exit-0 check (phase 2 uses
`timeout 60 … $smoke_args`; `start.sh` execs `"$@"`). Each directory's `smoke-cmd` runs a
deterministic check via the entrypoint:

| Image | `smoke-cmd` |
|-------|-------------|
| foundation | `python --version` |
| base-notebook | `jupyter --version` |
| minimal-notebook | `jupyter --version` |
| scipy-notebook | `python -c "import numpy, pandas, scipy, sklearn, matplotlib"` |
| datascience-notebook | `bash -lc "R --version && julia --version && python -c 'import rpy2'"` |

(Exact commands validated against the built env during implementation — the riskiest step
for the heavy R/Julia layer.)

## 13. CI / policy compliance checklist

- `base_image.rego`: foundation → UBI ref ✓; children → `${BASE_CONTAINER}` sentinel ✓ (edit §7).
- `test-base-images-pinned.sh`: UBI ref pinned ✓; `${BASE_CONTAINER}` exempt ✓.
- `test-chained-bases-pinned.sh` (new): `ARG BASE_CONTAINER` defaults are `ghcr.io/nq-rdl/…@sha256:` ✓.
- `validate-base-pins.yml`: foundation's UBI `@sha256:` is a multi-arch index covering amd64 ✓;
  child `${BASE_CONTAINER}` skipped ✓.
- `labels.rego`: five OCI labels; vendor `Research Data Laboratory` ✓.
- `image-meta/tags.rego`: CalVer tags match `X.Y.Z`/`X.Y`/`latest` ✓.
- `.hadolint.yaml`: `ghcr.io` trusted ✓ (edit §7).
- One changie fragment per phase, kind **Added**.

## 14. Phasing & rollout

Per the "full chain, phased delivery" decision — one spec, three PRs off
`feat/datascience-notebook-ubi9`:

| Phase | Images | Proves |
|-------|--------|--------|
| **1** | `docker-stacks-foundation-ubi9` + `base-notebook-ubi9` | pixi-in-image, `docker-bake.hcl` chaining, the §7 policy/pin edits, jovyan/GID-0 model, start-scripts + healthcheck. The plumbing risk lives here. |
| **2** | `minimal-notebook-ubi9` + `scipy-notebook-ubi9` | conda-forge TeX/ffmpeg/dvipng + the full SciPy stack; build weight. |
| **3** | `datascience-notebook-ubi9` | R + `r-*` + `rpy2` + Julia via conda-forge; the heaviest layer. |

Each phase: its own PR, changie fragment, green smoke + Trivy. On merge to `main`,
`build.yml` bakes the (cumulative) chain, points `latest`/`2026.6`/`2026.6.0` at the new
digests, and `publish-aliases` mints the suffix-less aliases. Consumers pin by `@sha256:`.

## 15. Risks & verification

- **Chaining/policy plumbing** (primary) — de-risked by making Phase 1 a thin two-image
  vertical slice that exercises bake `contexts`, the rego/hadolint/pin-test edits, and
  `--load` PR builds before any expensive layer.
- **User/permission model** — jovyan + GID 0 vs OpenShift random UID; **Codex review in
  flight** (§8); validated by running base-notebook as a non-1000 UID in Phase 1 smoke.
- **conda-forge breadth on UBI9/amd64** — R/`rpy2`/Julia resolve on conda-forge; pinned via
  `pixi.lock`. Verified by Phase 3 smoke actually invoking `R`, `julia`, `import rpy2`.
- **Image size** (~4–6 GB at datascience) — inherent to the stack; conda-forge prebuilt
  binaries beat in-image source compiles. Documented, not "fixed."
- **Trivy CRITICAL/HIGH** — UBI OS layer gated as today; conda-forge treated as a documented
  separate trust boundary (`--ignore-unfixed`); `dnf upgrade -y` during build. CI uploads
  SARIF non-blocking; the local pre-push hook blocks on fixable findings.
- **Heavy local builds** — if infeasible locally, rely on `build.yml` for the PR; use
  `SKIP_SMOKE`/`SKIP_TRIVY` for a push **only** when necessary and say so explicitly.

## 16. Open decisions (for spec review)

1. **Foundation image name** — `docker-stacks-foundation-ubi9` (faithful) vs the terser
   `notebook-foundation-ubi9`. Defaulting to the faithful name.
2. **Python version** — `3.12` chosen for conda-forge breadth; confirm vs `3.11`/`3.13`.
3. **User/permission model** — `jovyan`/UID 1000/**GID 0** (§8) — validated in Phase 1 (arbitrary-UID smoke passed).
