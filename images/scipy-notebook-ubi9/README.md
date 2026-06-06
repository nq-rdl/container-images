# scipy-notebook-ubi9

Jupyter `scipy-notebook` on UBI9 via **pixi** (conda-forge). Chained on `minimal-notebook-ubi9`. The full SciPy data-science stack.

- **OS additions (dnf, no EPEL):** `gcc`, `gcc-c++`, `make` (Cython / C-extension source builds)
- **conda-forge additions:** numpy, pandas, scipy, scikit-learn, scikit-image, matplotlib-base, seaborn, bokeh, altair, dask, numba, numexpr, bottleneck, statsmodels, sympy, patsy, h5py, pytables (`import tables`), sqlalchemy, openpyxl, xlrd, beautifulsoup4, cython, cloudpickle, dill, protobuf, ipympl, ipywidgets, widgetsnbextension, jupyterlab-git, and **`ffmpeg`** (matplotlib animation). `blas` pinned to the OpenBLAS build.
- **User:** `jovyan` (UID 1000, GID 0)

## Differences from upstream `quay.io/jupyter/scipy-notebook`
| Upstream (Debian) | This image (UBI9) |
|---|---|
| `build-essential` | `gcc gcc-c++ make` (dnf, no EPEL) |
| `apt install ffmpeg` | `ffmpeg` via conda-forge (no RPM Fusion/EPEL) |
| `conda-forge::blas=*=openblas` | `blas = { build = "openblas" }` (pixi build string) |
| `dvipng`, `cm-super` (inherited from minimal) | **Dropped** — absent from conda-forge, UBI9 base, and EPEL. matplotlib `text.usetex=True` is unsupported; the default `mathtext` renderer works. |

> `pytables` imports in Python as `tables`. ffmpeg enables `matplotlib.animation.FFMpegWriter`.
