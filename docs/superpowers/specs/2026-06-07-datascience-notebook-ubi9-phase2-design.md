# Datascience-notebook UBI9 — Phase 2 (minimal + scipy) design

- **Date:** 2026-06-07
- **Status:** Draft — ready to execute after PR #43 (Phase 1) merges
- **Plan:** `docs/superpowers/plans/2026-06-07-datascience-notebook-ubi9-phase2.md`
- **Extends:** `docs/superpowers/specs/2026-06-06-datascience-notebook-ubi9-design.md` (Phase-1 spec; §14 phasing)
- **Part of:** Issue #30 (phase 2 of 3)

## 1. Problem / context

Phase 1 shipped `docker-stacks-foundation-ubi9` + `base-notebook-ubi9` and all the enabling
machinery (pixi-in-image, `docker-bake.hcl` chaining, the `${BASE_CONTAINER}` chained-base
policy, GID-0 model, bake-aware CI/smoke). Phase 2 continues the chain with the next two
upstream layers — **`minimal-notebook`** and **`scipy-notebook`** — reusing every Phase-1
pattern. Because the hard enablement already exists, Phase 2 is almost entirely *new images*:
no policy, CI, or script changes are required (verified — the bake job builds the `datascience`
group, and `discover`/`smoke-test.sh` auto-detect `bake_target:` images).

## 2. Goals / Non-goals

**Goals**
- `minimal-notebook-ubi9` (chained on `base-notebook-ubi9`) and `scipy-notebook-ubi9` (chained
  on `minimal-notebook-ubi9`), upstream-mirror names + `-ubi9` suffix.
- Cumulative `pixi.toml` + committed `pixi.lock` per image (same model as Phase 1).
- Extend `docker-bake.hcl` (two targets + the `datascience` group) — nothing else.
- Pass all existing gates; `linux/amd64`; one changie fragment.

**Non-goals**
- `datascience-notebook-ubi9` (R + Julia) — Phase 3.
- EPEL (kept out — see §4). RPM Fusion. arm64. New policy/CI/script plumbing.
- matplotlib `text.usetex=True` rendering and `xelatex`-based PDF export (see §4).

## 3. Image set

| Image | Chains on | Adds |
|---|---|---|
| `minimal-notebook-ubi9` | `base-notebook-ubi9` | git/nano/vim-minimal/openssh-clients/unzip (dnf); `texlive-core` (conda-forge); `Rprofile.site` + `setup-scripts/` (vendored, for downstream R/Julia) |
| `scipy-notebook-ubi9` | `minimal-notebook-ubi9` | `gcc gcc-c++ make` (dnf); full SciPy stack + `ffmpeg` (conda-forge) |

Same Containerfile shape as Phase 1: `ARG BASE_CONTAINER=ghcr.io/nq-rdl/<parent>-ubi9:2026.6.0@sha256:<digest>`
→ `# hadolint ignore=DL3026` → `FROM ${BASE_CONTAINER}`; cumulative `pixi.toml` installed with
`pixi install --locked`; `fix-permissions "${NB_PIXI_PROJECT}"`; jovyan/UID 1000/GID 0 inherited.

## 4. Package strategy — and the one real fork: TeX/LaTeX on UBI9

The SciPy stack and `ffmpeg` are first-class on conda-forge (all names verified for linux-64),
so they install via pixi exactly like Phase 1's Jupyter packages — no OS/EPEL involvement.
`blas` is pinned to the OpenBLAS build (`build = "openblas"`).

**The hard part is TeX/LaTeX**, and it was settled by verifying against the *real* `ubi9/ubi:9.8`
image + conda-forge (not assumptions):

| Component | conda-forge | UBI9 base | EPEL9 | Decision |
|---|---|---|---|---|
| `pdflatex` / `bibtex` | ✅ `texlive-core` | ✗ | ✗ | **conda-forge** (minimal layer) |
| `xelatex` | ✗ (`texlive-core` omits it) | ✗ | ✗ (nothing provides `xelatex`) | **not available** → nbconvert PDF uses `pdflatex` |
| `dvipng` | ✗ | ✗ | ✗ | **dropped** |
| `cm-super` | ✗ | ✗ | ✗ | **dropped** |
| `ffmpeg` | ✅ | — | — | **conda-forge** (scipy layer) |

**Consequence (documented in image READMEs):** matplotlib's default `mathtext` renderer works;
`rcParams["text.usetex"]=True` (real-LaTeX text, which needs `dvipng`+`cm-super`) is unsupported.
nbconvert PDF export works via `pdflatex` (not the default `xelatex`). These are the only two
capabilities lost relative to upstream, and both have working substitutes. Crucially, this keeps
Phase 1's **no-EPEL** property — every hard package is either obtained from conda-forge or dropped
with documentation, never pulled from EPEL.

**Also dropped (consistent with Phase 1):** `xclip` (X11 clipboard, headless-irrelevant),
`run-one`/`RESTARTABLE` (no RPM). `nano-tiny`→`nano`, `vim-tiny`→`vim-minimal`,
`openssh-client`→`openssh-clients` (UBI naming).

## 5. Build system

`docker-bake.hcl` gains a `minimal-notebook` and a `scipy-notebook` target (each: `contexts`
mapping the parent ghcr ref → `target:<parent>`, `args BASE_CONTAINER=<parent tagless>`, the
three `TAG`/`MINOR`/`latest` tags, gha cache scope), both added to the `datascience` group. The
CI `bake` job (`docker buildx bake … datascience`) then builds the four-image chain in order; the
`discover` matrix-exclude, `smoke-test.sh`/`trivy-scan.sh` bake-detection, and the chained-base
policy all auto-handle the new images. **No other repo files change.**

## 6. Versioning, smoke, rollout

- Tags: `2026.6.0` / `2026.6` / `latest` (same CalVer line).
- smoke-cmd: minimal → `jupyter --version`; scipy → `python -c "import numpy, pandas, scipy, sklearn, matplotlib"`.
- Rollout: one Phase-2 PR (both images), off post-merge `main`. CI bakes + Trivy-scans all four.
  ARG `BASE_CONTAINER` digests are the **real pushed parent digests** (Phase 1 will be merged first).

## 7. Risks

- **Cumulative-lock removal:** each child `pixi.toml` must list ALL ancestor deps or
  `pixi install --locked` prunes them; the scipy extended-import smoke (imports from every
  ancestor layer) catches this.
- **scipy lock solve time:** 100+ packages; first `pixi lock` takes minutes (then cached).
- **TeX expectations:** consumers expecting `xelatex` or `usetex=True` must be told (READMEs do).

## 8. Open decisions (for review)

1. **TeX scope** — ship `texlive-core` (pdflatex, recommended) vs drop TeX from minimal entirely
   vs invest in the upstream TeX Live installer for full xelatex (heavy ~1 GB; not recommended).
2. **Phase-2 PR shape** — one PR for both images (recommended) vs two stacked sub-PRs.
