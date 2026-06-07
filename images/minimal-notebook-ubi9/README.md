# minimal-notebook-ubi9

Jupyter `minimal-notebook` on UBI9 via **pixi** (conda-forge). Chained on `base-notebook-ubi9`.

- **OS additions (dnf, no EPEL):** `git`, `nano`, `vim-minimal`, `openssh-clients`, `unzip`
- **conda-forge additions:** `texlive-core` (pdflatex + bibtex; nbconvert PDF needs its engine set to pdflatex — see note below)
- **Vendored:** `Rprofile.site`; `setup-scripts/` (Julia/env helpers for downstream images)
- **User:** `jovyan` (UID 1000, GID 0)

## Differences from upstream `quay.io/jupyter/minimal-notebook`
| Upstream (Debian) | This image (UBI9) |
|---|---|
| `nano-tiny` + `update-alternatives` | `nano` (direct) |
| `vim-tiny` | `vim-minimal` |
| `openssh-client` | `openssh-clients` |
| `texlive-xetex` / `-fonts-recommended` / `-plain-generic` | `texlive-core` via conda-forge — **pdflatex/bibtex only, no `xelatex`**. nbconvert defaults to `xelatex`, so PDF export requires selecting pdflatex (see note below). |
| `dvipng`, `cm-super` | **Dropped** — absent from conda-forge, UBI9 base, and EPEL. matplotlib `text.usetex=True` is unsupported; the default `mathtext` renderer works. |
| `xclip` | **Dropped** — X11 clipboard; irrelevant headless |
| `run-one` | **Dropped** — no RPM |

> **nbconvert PDF export:** nbconvert's default LaTeX engine is `xelatex`, which is **not** included (`texlive-core` ships `pdflatex` + `bibtex` only). To export PDF, override the engine on `PDFExporter`, e.g.
> `jupyter nbconvert --to pdf --PDFExporter.latex_command='["pdflatex", "{filename}"]' notebook.ipynb`.
