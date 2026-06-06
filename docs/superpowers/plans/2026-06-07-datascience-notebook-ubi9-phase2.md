# Datascience-notebook UBI9 — Phase 2 (minimal-notebook + scipy-notebook) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the next two UBI9 images in the Jupyter datascience-notebook chain —
`minimal-notebook-ubi9` (chained on `base-notebook-ubi9`) and `scipy-notebook-ubi9`
(chained on `minimal-notebook-ubi9`) — and wire both into the root `docker-bake.hcl`
`datascience` group that Phase 1 established.

**Architecture:** Same per-image `Containerfile` + `docker-bake.hcl` `contexts` pattern as
Phase 1. Each image carries a **cumulative** `pixi.toml` + committed `pixi.lock`. The OS layer
(dnf, full `ubi9/ubi`, **no EPEL**) adds only what conda-forge cannot supply. All Phase-1
policy/CI/script plumbing (`base_image.rego` sentinel, `test-chained-bases-pinned.sh`, hadolint
`ghcr.io` trust, the CI `bake` job, bake auto-detection in `smoke-test.sh`/`trivy-scan.sh`) is
already in place and auto-handles new `bake_target` images **without modification**.

**Tech Stack:** UBI9, pixi 0.70.1, conda-forge, `docker buildx bake`, conftest/OPA, hadolint, Trivy.

**Spec:** `docs/superpowers/specs/2026-06-07-datascience-notebook-ubi9-phase2-design.md` (extends the Phase-1 spec `…/2026-06-06-datascience-notebook-ubi9-design.md`).

**Pinned upstream:** jupyter/docker-stacks commit `96322b6b179e4de61eb6ddbbdadcd8fba61662f7` (same SHA as Phase 1).

**Prerequisites:** **Phase 1 (PR #43) is merged to `main`** and both
`ghcr.io/nq-rdl/docker-stacks-foundation-ubi9:2026.6.0` and
`ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0` are pushed to GHCR with resolvable manifest digests.
Start Phase 2 from a fresh branch off the post-merge `main` (e.g. `feat/datascience-notebook-ubi9-phase2`).

**Conventions:** conventional-commit messages; do **not** push until the phase is green.

---

## ⚠️ Verified package facts (do NOT deviate — confirmed against the real `ubi9/ubi:9.8` image + conda-forge, 2026-06)

| Need | Verdict | Decision |
|---|---|---|
| SciPy stack (numpy/pandas/scipy/scikit-learn/…) | All on conda-forge ✅ (exact names in Task 6) | conda-forge via pixi |
| `ffmpeg` (matplotlib animation) | conda-forge ✅ | conda-forge via pixi (NOT RPM Fusion/EPEL) |
| `texlive-core` (nbconvert PDF) | conda-forge ✅ — provides **`pdflatex` + `bibtex` only, NOT `xelatex`** | conda-forge via pixi; document pdflatex-only |
| `dvipng` | **NOT** on conda-forge, **NOT** in UBI9 base, **NOT** in EPEL9 | **DROP** (document: matplotlib `usetex=True` unsupported) |
| `cm-super` | **NOT** on conda-forge, **NOT** in UBI9 base, **NOT** in EPEL9 (RHEL ships `texlive-cm-super` but it is absent from UBI's repo subset) | **DROP** (same as dvipng) |
| `blas` OpenBLAS variant | conda-forge build string is the bare word `openblas` | `blas = { version = "*", build = "openblas" }` |
| `jupyterlab-git` | conda-forge **noarch** (resolves for linux-64) | conda-forge via pixi |
| OS tools (git/nano/vim-minimal/openssh-clients/unzip; gcc/gcc-c++/make) | UBI9 BaseOS/AppStream ✅ (curl/tzdata/less already in the base) | dnf, no EPEL |

**No EPEL is introduced in Phase 2** — every hard package is either obtained from conda-forge or dropped with documentation. matplotlib's default `mathtext` renderer works without `dvipng`/`cm-super`; only `rcParams["text.usetex"]=True` (real-LaTeX text) is unsupported.

---

## File map (Phase 2)

| Path | Responsibility |
|------|----------------|
| `images/minimal-notebook-ubi9/Containerfile` | Chain on `base-notebook-ubi9`; dnf thin OS tools; `texlive-core` via conda-forge; Rprofile.site + setup-scripts COPY |
| `images/minimal-notebook-ubi9/pixi.toml` / `pixi.lock` | Cumulative: base-notebook deps + `texlive-core` |
| `images/minimal-notebook-ubi9/image.yaml` / `README.md` / `smoke-cmd` | Metadata + docs |
| `images/minimal-notebook-ubi9/Rprofile.site` + `setup-scripts/*` | Vendored from upstream @96322b6 |
| `images/scipy-notebook-ubi9/Containerfile` | Chain on `minimal-notebook-ubi9`; `gcc gcc-c++ make` via dnf; full SciPy + ffmpeg via conda-forge |
| `images/scipy-notebook-ubi9/pixi.toml` / `pixi.lock` | Cumulative: minimal deps + full SciPy + ffmpeg |
| `images/scipy-notebook-ubi9/image.yaml` / `README.md` / `smoke-cmd` | Metadata + docs |
| `docker-bake.hcl` | ADD `minimal-notebook` + `scipy-notebook` targets; ADD both to `datascience` group |
| `.changes/unreleased/Added-<timestamp>.yaml` | changie fragment |

No policy/CI/script files change (verified in Task 1 + Task 8).

---

## Task 1: Preflight — confirm Phase-1 infra auto-handles new bake images (read-only)

- [ ] **Step 1:** `bash tests/test-chained-bases-pinned.sh` → exits 0.
- [ ] **Step 2:** `docker buildx bake --file docker-bake.hcl --print datascience | jq '.target | keys'` → lists the existing Phase-1 targets, no parse error. (Note `.target | keys`, NOT `keys` — the top-level bake JSON has `group` + `target`.)
- [ ] **Step 3:** `grep -lR --include=image.yaml 'bake_target:' images/ | sort` → lists the two Phase-1 images; `smoke-test.sh` uses this same grep so new `bake_target` images are auto-detected.
- [ ] **Step 4:** `grep ghcr.io .hadolint.yaml` and `grep BASE_CONTAINER policy/base_image.rego` → confirm the ghcr trust + `${BASE_CONTAINER}` sentinel are live.

No commits — read-only preflight.

---

## Task 2: Resolve the `base-notebook-ubi9` manifest digest

- [ ] **Step 1:** Resolve the real pushed digest for the `minimal-notebook` `ARG BASE_CONTAINER` default:
```bash
docker buildx imagetools inspect ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0 \
  --format "{{json .Manifest}}" | jq -r .digest
```
Record as `<BASE_NOTEBOOK_DIGEST>` (format `sha256:<64-hex>`). Used in Task 3 Step 5. (Phase 1 must be merged + pushed; the `test-chained-bases-pinned.sh` guard rejects a malformed/missing pin.)

---

## Task 3: `minimal-notebook-ubi9` image

**Files:** `Rprofile.site`, `setup-scripts/{activate_notebook_custom_env.py,setup-julia-packages.bash,setup_julia.py}`, `pixi.toml`, `pixi.lock`, `Containerfile`, `image.yaml`, `README.md`, `smoke-cmd` (all under `images/minimal-notebook-ubi9/`).

- [ ] **Step 1: Vendor Rprofile.site + setup-scripts from upstream (pinned SHA)**
```bash
mkdir -p images/minimal-notebook-ubi9/setup-scripts
SHA=96322b6b179e4de61eb6ddbbdadcd8fba61662f7
B="https://raw.githubusercontent.com/jupyter/docker-stacks/$SHA/images/minimal-notebook"
curl -fsSL "$B/Rprofile.site" -o images/minimal-notebook-ubi9/Rprofile.site
for f in activate_notebook_custom_env.py setup-julia-packages.bash setup_julia.py; do
  curl -fsSL "$B/setup-scripts/$f" -o "images/minimal-notebook-ubi9/setup-scripts/$f"
done
chmod +x images/minimal-notebook-ubi9/setup-scripts/setup-julia-packages.bash
ls images/minimal-notebook-ubi9/Rprofile.site images/minimal-notebook-ubi9/setup-scripts/
```
Expected: `Rprofile.site` + the three setup-scripts present.

- [ ] **Step 2: Write the cumulative `pixi.toml`**

Create `images/minimal-notebook-ubi9/pixi.toml`:
```toml
[workspace]
name = "minimal-notebook"
channels = ["conda-forge"]
platforms = ["linux-64"]

[dependencies]
# ── inherited from docker-stacks-foundation-ubi9 ──────────────────────────
python = "3.12.*"
pip = "*"
jupyter_core = "*"
# ── inherited from base-notebook-ubi9 ────────────────────────────────────
jupyterhub-singleuser = "*"
jupyterlab = "*"
nbclassic = "*"
notebook = ">=7.2.2"
fonts-conda-forge = "*"
# ── this layer (minimal-notebook-ubi9) ───────────────────────────────────
# TeX Live via conda-forge: provides pdflatex + bibtex for nbconvert PDF export.
# NOTE: conda-forge texlive-core does NOT ship xelatex; nbconvert PDF uses pdflatex.
# dvipng + cm-super are NOT available on conda-forge OR UBI9/EPEL and are NOT installed
# (matplotlib text.usetex=True is unsupported; the default mathtext renderer works).
texlive-core = "*"
```

- [ ] **Step 3: Generate the lockfile**
```bash
cd images/minimal-notebook-ubi9 && pixi lock && cd -
test -f images/minimal-notebook-ubi9/pixi.lock && echo "lock OK"
grep -c texlive images/minimal-notebook-ubi9/pixi.lock   # expect non-zero
```
Expected: `pixi.lock` at format v7; texlive entries present.

- [ ] **Step 4: Write the `Containerfile`** (substitute `<BASE_NOTEBOOK_DIGEST>` from Task 2)

Create `images/minimal-notebook-ubi9/Containerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
#
# minimal-notebook on UBI9 (chained on base-notebook-ubi9)
# Blueprint: jupyter/docker-stacks@96322b6 images/minimal-notebook/Dockerfile
# Changes: BASE_IMAGE -> ${BASE_CONTAINER} (repo-internal UBI-rooted base); apt -> dnf;
#          nano-tiny -> nano (drop update-alternatives); vim-tiny -> vim-minimal;
#          openssh-client -> openssh-clients; texlive-* (Debian) -> conda-forge texlive-core
#          (pdflatex/bibtex; NO xelatex); dvipng + cm-super DROPPED (absent from conda-forge,
#          UBI9 base, and EPEL — usetex=True unsupported); xclip DROPPED (headless, no X11);
#          run-one DROPPED (no RPM). Rprofile.site + setup-scripts vendored from upstream.
#
ARG BASE_CONTAINER=ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0@sha256:<BASE_NOTEBOOK_DIGEST>
# hadolint ignore=DL3026
FROM ${BASE_CONTAINER}

LABEL org.opencontainers.image.title="minimal-notebook-ubi9"
LABEL org.opencontainers.image.description="Jupyter minimal-notebook on UBI9 (git/vim/ssh + TeX via conda-forge)"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

# Thin OS tools absent from the base image. curl/tzdata/less are pre-installed on full ubi9/ubi.
# (TeX/dvipng/cm-super are NOT here — see header: texlive-core comes from conda-forge; dvipng/
# cm-super are dropped. No EPEL.)
RUN dnf install -y --setopt=install_weak_deps=0 --nodocs \
        git \
        nano \
        vim-minimal \
        openssh-clients \
        unzip \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/yum

USER ${NB_UID}

# Cumulative pixi.toml: all ancestor deps + texlive-core for this layer.
COPY --chown=${NB_UID}:${NB_GID} pixi.toml pixi.lock /opt/nb/
RUN pixi install --locked --manifest-path /opt/nb/pixi.toml \
    && rm -rf /tmp/pixi-cache \
    && fix-permissions "${NB_PIXI_PROJECT}" \
    && fix-permissions "/home/${NB_USER}"

# Rprofile.site: R plot mimetypes so plots render in the browser (path mirrors upstream).
COPY --chown=${NB_UID}:${NB_GID} Rprofile.site "${CONDA_DIR}/lib/R/etc/"
# setup-scripts: helpers for downstream images (Julia kernel, custom conda env activation).
COPY --chown=${NB_UID}:${NB_GID} setup-scripts/ /opt/setup-scripts/

USER root
RUN fix-permissions /opt/setup-scripts

USER ${NB_UID}
WORKDIR "${HOME}"
```

- [ ] **Step 5: Write `image.yaml`**
```yaml
name: minimal-notebook-ubi9
description: Jupyter minimal-notebook on UBI9 (git, vim, TeX via conda-forge/texlive-core)
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: ghcr.io
  repository: nq-rdl/base-notebook-ubi9
  version: "2026.6.0"
runtime:
  name: jupyter-minimal-notebook
tags:
  - "2026.6.0"
  - "2026.6"
  - "latest"
depends_on: base-notebook-ubi9
bake_target: minimal-notebook
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 6: Write `smoke-cmd` + `README.md`**

`smoke-cmd`:
```
jupyter --version
```
`README.md`:
```markdown
# minimal-notebook-ubi9

Jupyter `minimal-notebook` on UBI9 via **pixi** (conda-forge). Chained on `base-notebook-ubi9`.

- **OS additions (dnf, no EPEL):** `git`, `nano`, `vim-minimal`, `openssh-clients`, `unzip`
- **conda-forge additions:** `texlive-core` (pdflatex + bibtex for nbconvert PDF)
- **Vendored:** `Rprofile.site`; `setup-scripts/` (Julia/env helpers for downstream images)
- **User:** `jovyan` (UID 1000, GID 0)

## Differences from upstream `quay.io/jupyter/minimal-notebook`
| Upstream (Debian) | This image (UBI9) |
|---|---|
| `nano-tiny` + `update-alternatives` | `nano` (direct) |
| `vim-tiny` | `vim-minimal` |
| `openssh-client` | `openssh-clients` |
| `texlive-xetex` / `-fonts-recommended` / `-plain-generic` | `texlive-core` via conda-forge — **pdflatex/bibtex only, no `xelatex`** (nbconvert PDF uses pdflatex) |
| `dvipng`, `cm-super` | **Dropped** — absent from conda-forge, UBI9 base, and EPEL. matplotlib `text.usetex=True` is unsupported; the default `mathtext` renderer works. |
| `xclip` | **Dropped** — X11 clipboard; irrelevant headless |
| `run-one` | **Dropped** — no RPM |
```

- [ ] **Step 7: Lint + policy-check**
```bash
pixi run lint-containerfiles
pixi run policy-check-containerfiles
pixi run policy-check-image-meta
pixi run policy-check-chained-bases
```
Expected: all PASS (the `# hadolint ignore=DL3026` handles the ARG-expanded ghcr FROM; the pin guard validates the `ARG BASE_CONTAINER` default).

- [ ] **Step 8: Commit**
```bash
git add images/minimal-notebook-ubi9
git commit -m "feat(minimal-notebook-ubi9): Jupyter minimal-notebook on UBI9, chained on base-notebook (#30, phase 2)"
```

---

## Task 4: Add `minimal-notebook` to `docker-bake.hcl` + build + smoke

- [ ] **Step 1:** In `docker-bake.hcl`, add `"minimal-notebook"` to the `datascience` group `targets` list, and append:
```hcl
target "minimal-notebook" {
  context    = "images/minimal-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = { "ghcr.io/nq-rdl/base-notebook-ubi9" = "target:base-notebook" }
  args     = { BASE_CONTAINER = "ghcr.io/nq-rdl/base-notebook-ubi9" }
  tags = [
    "${REGISTRY}/minimal-notebook-ubi9:${TAG}",
    "${REGISTRY}/minimal-notebook-ubi9:${MINOR}",
    "${REGISTRY}/minimal-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=minimal-notebook-ubi9"]
  cache-to   = ["type=gha,scope=minimal-notebook-ubi9,mode=max"]
}
```
- [ ] **Step 2:** `docker buildx bake --file docker-bake.hcl --print datascience | jq '.target | keys'` → includes `minimal-notebook`.
- [ ] **Step 3: Build + smoke** (needs the docker-container buildx driver for `target:` contexts — `docker buildx create --name nbbuild --driver docker-container --use` if not already active):
```bash
docker buildx bake --file docker-bake.hcl --load minimal-notebook
docker run --rm ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0 jupyter --version
# TeX: pdflatex is present (texlive-core); xelatex is intentionally NOT present.
docker run --rm ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0 bash -c 'pdflatex --version | head -1'
# Vendored files present (single-quote so ${CONDA_DIR} expands INSIDE the container):
docker run --rm ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0 \
  bash -c 'ls /opt/setup-scripts/ && test -f "${CONDA_DIR}/lib/R/etc/Rprofile.site" && echo RPROFILE_OK'
# Arbitrary-UID (OpenShift SCC):
docker run --rm --user 4711:0 ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0 jupyter --version
```
Expected: `jupyter --version` lists components; `pdflatex` prints a version; `RPROFILE_OK`; arbitrary-UID run exits 0.
- [ ] **Step 4:** `pixi run lint-all && pixi run policy-check` → green.
- [ ] **Step 5:** Commit: `git add docker-bake.hcl && git commit -m "build(bake): add minimal-notebook target; extend datascience group (#30, phase 2)"`

---

## Task 5: Resolve the `minimal-notebook-ubi9` manifest digest

- [ ] **Step 1:** For the `scipy-notebook` `ARG BASE_CONTAINER` default — after `minimal-notebook-ubi9` is pushed (Task 4 merged/pushed), resolve:
```bash
docker buildx imagetools inspect ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0 \
  --format "{{json .Manifest}}" | jq -r .digest
```
Record as `<MINIMAL_NOTEBOOK_DIGEST>`. (For a single-PR Phase 2 where minimal isn't pushed yet, use a well-formed placeholder — bake's `contexts` override makes the digest unused in-graph; the pin guard only checks format. Repin to the real digest before merge if minimal is pushed first.)

---

## Task 6: `scipy-notebook-ubi9` image

**Files:** `pixi.toml`, `pixi.lock`, `Containerfile`, `image.yaml`, `README.md`, `smoke-cmd` (under `images/scipy-notebook-ubi9/`).

- [ ] **Step 1: Write the cumulative `pixi.toml`** (all conda-forge names verified for linux-64)
```toml
[workspace]
name = "scipy-notebook"
channels = ["conda-forge"]
platforms = ["linux-64"]

[dependencies]
# ── inherited: foundation ──
python = "3.12.*"
pip = "*"
jupyter_core = "*"
# ── inherited: base-notebook ──
jupyterhub-singleuser = "*"
jupyterlab = "*"
nbclassic = "*"
notebook = ">=7.2.2"
fonts-conda-forge = "*"
# ── inherited: minimal-notebook ──
texlive-core = "*"
# ── this layer: scipy-notebook ──
altair = "*"
beautifulsoup4 = "*"
blas = { version = "*", build = "openblas" }   # OpenBLAS variant (exact build string)
bokeh = "*"
bottleneck = "*"
cloudpickle = "*"
cython = "*"
dask = "*"
dill = "*"
ffmpeg = "*"               # matplotlib animation; conda-forge (NOT RPM Fusion/EPEL)
h5py = "*"
ipympl = "*"
ipywidgets = "*"
jupyterlab-git = "*"       # noarch on conda-forge; resolves for linux-64
matplotlib-base = "*"
numba = "*"
numexpr = "*"
openpyxl = "*"
pandas = "*"
patsy = "*"
protobuf = "*"
pytables = "*"             # python import name is `tables`
scikit-image = "*"
scikit-learn = "*"
scipy = "*"
seaborn = "*"
sqlalchemy = "*"
statsmodels = "*"
sympy = "*"
widgetsnbextension = "*"
xlrd = "*"
```

- [ ] **Step 2: Generate the lockfile** (large — 100+ pkgs; allow several minutes)
```bash
cd images/scipy-notebook-ubi9 && pixi lock && cd -
test -f images/scipy-notebook-ubi9/pixi.lock && echo "lock OK"
grep -E '(scipy|scikit-learn|ffmpeg|texlive-core|jupyterlab-git)' images/scipy-notebook-ubi9/pixi.lock | head
grep -E 'openblas' images/scipy-notebook-ubi9/pixi.lock | head -3   # confirm openblas blas variant
```
Expected: key packages + an `openblas` build present.

- [ ] **Step 3: Write the `Containerfile`** (substitute `<MINIMAL_NOTEBOOK_DIGEST>` from Task 5)
```dockerfile
# syntax=docker/dockerfile:1.7
#
# scipy-notebook on UBI9 (chained on minimal-notebook-ubi9)
# Blueprint: jupyter/docker-stacks@96322b6 images/scipy-notebook/Dockerfile
# Changes: BASE_IMAGE -> ${BASE_CONTAINER}; apt -> dnf; build-essential -> gcc gcc-c++ make;
#          ffmpeg -> conda-forge::ffmpeg (no RPM Fusion/EPEL); dvipng + cm-super DROPPED
#          (absent from conda-forge, UBI9, EPEL; usetex=True unsupported); all conda installs
#          -> pixi install --locked. No COPY (no scripts at this layer).
#
ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:<MINIMAL_NOTEBOOK_DIGEST>
# hadolint ignore=DL3026
FROM ${BASE_CONTAINER}

LABEL org.opencontainers.image.title="scipy-notebook-ubi9"
LABEL org.opencontainers.image.description="Jupyter scipy-notebook on UBI9 — full SciPy stack via conda-forge (pixi)"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="BSD-3-Clause"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

# UBI9 equivalents of Debian build-essential (BaseOS/AppStream; no EPEL). Needed for Cython
# .pyx compilation and any source-built C extension (rare with conda-forge binaries).
RUN dnf install -y --setopt=install_weak_deps=0 --nodocs \
        gcc \
        gcc-c++ \
        make \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/yum

USER ${NB_UID}

# Cumulative pixi.toml: all ancestor deps + the full SciPy stack + ffmpeg.
COPY --chown=${NB_UID}:${NB_GID} pixi.toml pixi.lock /opt/nb/
RUN pixi install --locked --manifest-path /opt/nb/pixi.toml \
    && python -c "import numpy, pandas, scipy, sklearn, matplotlib" \
    && rm -rf /tmp/pixi-cache \
    && fix-permissions "${NB_PIXI_PROJECT}" \
    && fix-permissions "/home/${NB_USER}"

USER ${NB_UID}
WORKDIR "${HOME}"
```

- [ ] **Step 4: Write `image.yaml`**
```yaml
name: scipy-notebook-ubi9
description: Jupyter scipy-notebook on UBI9 — full SciPy stack via conda-forge (pixi)
owners:
  - nq-rdl/platform
  - nq-rdl/data-engineering
platforms:
  - linux/amd64
base:
  registry: ghcr.io
  repository: nq-rdl/minimal-notebook-ubi9
  version: "2026.6.0"
runtime:
  name: jupyter-scipy-notebook
tags:
  - "2026.6.0"
  - "2026.6"
  - "latest"
depends_on: minimal-notebook-ubi9
bake_target: scipy-notebook
support:
  status: stable
  eol: "2027-06-30"
```

- [ ] **Step 5: Write `smoke-cmd` + `README.md`**

`smoke-cmd`:
```
python -c "import numpy, pandas, scipy, sklearn, matplotlib"
```
`README.md`: document the OS additions (`gcc gcc-c++ make`), the conda-forge SciPy stack (table), `ffmpeg` from conda-forge, and that `dvipng`/`cm-super` are **not** present so `matplotlib text.usetex=True` is unsupported (mathtext works). Note the upstream→UBI deltas (`build-essential`→`gcc gcc-c++ make`, `apt ffmpeg`→conda-forge ffmpeg, `blas=*=openblas`→pixi build string).

- [ ] **Step 6: Lint + policy-check**
```bash
pixi run lint-containerfiles
pixi run policy-check-containerfiles && pixi run policy-check-image-meta && pixi run policy-check-chained-bases
```
- [ ] **Step 7: Commit**
```bash
git add images/scipy-notebook-ubi9
git commit -m "feat(scipy-notebook-ubi9): Jupyter scipy-notebook on UBI9, chained on minimal-notebook (#30, phase 2)"
```

---

## Task 7: Add `scipy-notebook` to `docker-bake.hcl` + build + smoke

- [ ] **Step 1:** Add `"scipy-notebook"` to the `datascience` group, and append:
```hcl
target "scipy-notebook" {
  context    = "images/scipy-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = { "ghcr.io/nq-rdl/minimal-notebook-ubi9" = "target:minimal-notebook" }
  args     = { BASE_CONTAINER = "ghcr.io/nq-rdl/minimal-notebook-ubi9" }
  tags = [
    "${REGISTRY}/scipy-notebook-ubi9:${TAG}",
    "${REGISTRY}/scipy-notebook-ubi9:${MINOR}",
    "${REGISTRY}/scipy-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=scipy-notebook-ubi9"]
  cache-to   = ["type=gha,scope=scipy-notebook-ubi9,mode=max"]
}
```
- [ ] **Step 2:** `docker buildx bake --file docker-bake.hcl --print datascience | jq '.target | keys'` → all four targets.
- [ ] **Step 3: Build + smoke**
```bash
docker buildx bake --file docker-bake.hcl --load scipy-notebook
docker run --rm ghcr.io/nq-rdl/scipy-notebook-ubi9:2026.6.0 python -c "import numpy, pandas, scipy, sklearn, matplotlib"
# Full-stack import (note: pytables imports as `tables`):
docker run --rm ghcr.io/nq-rdl/scipy-notebook-ubi9:2026.6.0 \
  python -c "import altair, bokeh, dask, numba, statsmodels, sympy, h5py, tables, sqlalchemy, seaborn, skimage; print('SciPy stack OK')"
# ffmpeg / matplotlib animation:
docker run --rm ghcr.io/nq-rdl/scipy-notebook-ubi9:2026.6.0 \
  python -c "import matplotlib; matplotlib.use('Agg'); from matplotlib.animation import FFMpegWriter; print('FFMpegWriter OK')"
# Arbitrary-UID:
docker run --rm --user 4711:0 ghcr.io/nq-rdl/scipy-notebook-ubi9:2026.6.0 \
  python -c "import numpy, pandas, scipy, sklearn, matplotlib"
```
Expected: all exit 0.
- [ ] **Step 4:** `pixi run lint-all && pixi run policy-check` → green.
- [ ] **Step 5:** Commit: `git add docker-bake.hcl && git commit -m "build(bake): add scipy-notebook target; datascience group now four images (#30, phase 2)"`

---

## Task 8: Verify no policy/CI/script changes are needed (read-only)

- [ ] **Step 1:** `docker buildx bake --file docker-bake.hcl --print datascience | jq '.target | keys'` → four targets (the CI `bake` job builds the `datascience` group verbatim — no `build.yml` change).
- [ ] **Step 2:** `for d in images/minimal-notebook-ubi9 images/scipy-notebook-ubi9; do yq -e '.bake_target' "$d/image.yaml" >/dev/null && echo "$d excluded from matrix OK"; done` → both OK (the `discover` job auto-excludes them).
- [ ] **Step 3:** `grep -lR --include=image.yaml 'bake_target:' images/ | wc -l` → 4 (smoke-test.sh auto-detects them).
- [ ] **Step 4:** `docker buildx bake --file docker-bake.hcl --print scipy-notebook | jq '.target."scipy-notebook".tags'` → the three `:2026.6.0/2026.6/latest` tags trivy-scan.sh will scan.

---

## Task 9: Changelog + full gate + PR

- [ ] **Step 1:** `changie new --kind Added --body "UBI9 Jupyter minimal-notebook + scipy-notebook images (pixi/conda-forge: texlive-core, full SciPy stack, ffmpeg) chained on base-notebook via docker buildx bake (#30, phase 2)."`  (Prefer `changie new` so the `time:` field is auto-added; if creating the YAML manually, include `kind:`, `body:`, AND `time:` (RFC-3339) — fragments without `time:` break `changie batch`.)
- [ ] **Step 2:** Commit the fragment: `git add .changes/unreleased/ && git commit -m "docs(changelog): datascience-notebook UBI9 phase 2 fragment (#30)"`
- [ ] **Step 3:** Full gate: `pixi run lint-all && pixi run policy-check` → green (8 sub-checks; four new Containerfiles, two new image.yaml, two new chained-base pins). If k3d is available, optionally `scripts/smoke-test.sh` (builds all images + k3d). If k3d is absent, do a scoped k3d pod-start smoke of just the two new images (see Phase-1 finish notes), or rely on CI.
- [ ] **Step 4:** Push (if the env lacks k3d, `SKIP_SMOKE=1 SKIP_TRIVY=1` and disclose — CI's bake job builds + Trivy-scans all four). Open the PR:
```bash
git push -u origin <phase-2-branch>
gh pr create --base main \
  --title "feat: UBI9 minimal-notebook + scipy-notebook via pixi + bake (#30, phase 2)" \
  --body "Phase 2 of the datascience-notebook UBI9 stack. Adds minimal-notebook-ubi9 + scipy-notebook-ubi9, chained on the Phase-1 images via docker-bake.hcl contexts. dvipng/cm-super dropped (unavailable on UBI9+conda-forge; usetex unsupported, mathtext works); texlive-core gives pdflatex (no xelatex); ffmpeg + full SciPy stack via conda-forge; no EPEL, no policy/CI/script changes. Part of #30."
```
Expected: CI `bake` builds the four-image chain + Trivy; all checks green.

---

## Self-review notes (author)

- **Spec coverage:** image set → Tasks 3, 6; cumulative pixi → Tasks 3 Step 2 / 6 Step 1; bake → Tasks 4, 7; policy reuse → Tasks 1, 8 (no changes); user model → arbitrary-UID smokes (4 Step 3, 7 Step 3); smoke-cmd → 3 Step 6 / 6 Step 5; changelog/PR → Task 9.
- **Exec-time resolutions (not placeholders):** `<BASE_NOTEBOOK_DIGEST>` (Task 2), `<MINIMAL_NOTEBOOK_DIGEST>` (Task 5), generated `pixi.lock` files.
- **No EPEL, no dropped-package surprises:** `dvipng`/`cm-super` are dropped by design (verified absent from conda-forge + UBI9 base + EPEL9); `texlive-core` is pdflatex/bibtex only (no xelatex). Both reductions are documented in the image READMEs. matplotlib `usetex=True` and xelatex-based nbconvert are the only lost capabilities; both have working substitutes (mathtext; pdflatex).
- **`import tables`** is the correct python import for the `pytables` conda package (Task 7 Step 3).
- **`blas = { build = "openblas" }`** is the exact conda-forge build string (verified) — equivalent to upstream `conda-forge::blas=*=openblas`.
- **Risk to watch first:** the scipy cumulative `pixi.lock` must list ALL ancestor deps (foundation+base+minimal) or `pixi install --locked` removes them from the inherited prefix; the extended-import smoke (Task 7 Step 3) exercises packages from every ancestor layer to catch this.
- **Deferred to Phase 3:** `datascience-notebook-ubi9` (R + `r-*` + `rpy2` + Julia via conda-forge; `gcc-gfortran`; dejavu fonts) — completes the `/goal` and closes #30.
