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
