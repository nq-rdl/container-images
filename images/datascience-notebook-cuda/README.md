# datascience-notebook-cuda

Public, sensitive-free GPU base for downstream notebook overlays: upstream
`jupyter/datascience-notebook` (digest-pinned) + the CUDA 12.6 runtime and
`pytorch-gpu` from conda-forge.

## Scope

- **Public** and **contains nothing sensitive** — no certificates, internal
  hostnames, proxy configuration, or credentials. Those live only in the private
  overlays that chain on this image.
- Ships the CUDA **runtime** only. No NVIDIA kernel driver is baked in — the host
  GPU operator injects the matching driver at runtime via CDI.
- Ubuntu-based (not UBI); a UBI rebuild is future state.

## Consuming it

Chain on the published digest from a private overlay:

```dockerfile
ARG BASE_CONTAINER=ghcr.io/nq-rdl/datascience-notebook-cuda:12.6@sha256:<digest>
FROM ${BASE_CONTAINER}
```
