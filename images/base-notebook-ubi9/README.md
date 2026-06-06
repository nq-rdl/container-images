# base-notebook-ubi9

Jupyter `base-notebook` on UBI9: JupyterLab, Notebook (>=7.2.2), NBClassic, and
JupyterHub single-user — chained on `docker-stacks-foundation-ubi9`.

- **Base:** `ghcr.io/nq-rdl/docker-stacks-foundation-ubi9` (digest-pinned, UBI-rooted)
- **Server:** `start-notebook.py` (`CMD`); `start-singleuser.py` for JupyterHub
- **Port:** 8888 (`EXPOSE`); `HEALTHCHECK` via `docker_healthcheck.py`
- **User:** `jovyan` (UID 1000, GID 0)

Dropped vs upstream: `run-one`/`RESTARTABLE` (rarely used; no RPM). `pandoc` is a pinned
static binary; fonts via `liberation-fonts` RPMs + `fonts-conda-forge` (conda-forge).
