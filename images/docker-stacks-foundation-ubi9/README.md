# docker-stacks-foundation-ubi9

Jupyter `docker-stacks-foundation`, ported to UBI9 and built with **pixi** (conda-forge).
The root of the nq-rdl datascience-notebook chain.

- **Base:** `registry.access.redhat.com/ubi9/ubi` (digest-pinned)
- **Packages:** pixi-managed conda-forge env at `/opt/nb/.pixi/envs/default` (exported as `CONDA_DIR`)
- **User:** `jovyan` (UID 1000, **GID 0** — OpenShift arbitrary-UID friendly)
- **Entrypoint:** `tini -g -- start.sh` (upstream runtime contract)

Differs from upstream: Ubuntu→UBI9, micromamba/conda→pixi with a committed `pixi.lock`,
`NB_GID` 100→0. Not meant to be run directly; downstream images add the notebook server.
