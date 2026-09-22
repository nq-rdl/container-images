# datascience-notebook-cuda

This public GPU notebook combines the UBI9 SciPy notebook with CUDA 12.6,
cuDNN, and `pytorch-gpu` from conda-forge. The cumulative Pixi manifest and
lockfile define the Python environment at `/opt/nb/.pixi/envs/default`.

## Scope and migration

- The image inherits JupyterLab, JupyterHub integration, and the Python SciPy
  stack from the digest-pinned `scipy-notebook-ubi9` image.
- This replaces the Ubuntu-based Jupyter vendor image. R and Julia kernels
  from that image are not included.
- The image contains no internal certificates, hostnames, proxy configuration,
  or credentials. Keep these in private downstream overlays.
- The host supplies the NVIDIA driver through the Container Device Interface
  (CDI). The image contains CUDA userspace libraries and cuDNN, with no kernel driver.
- The image name and `12.6` tag remain unchanged. Rebuild downstream overlays
  for UBI9 and replace Ubuntu-specific package installation commands.

## Build and validate

To build on a host without a GPU, run:

```bash
docker build -t localhost/datascience-notebook-cuda:issue84 \
  -f images/datascience-notebook-cuda/Containerfile images/datascience-notebook-cuda
```

The build verifies UBI9, Python imports, CUDA 12.6, cuDNN loading, and a CPU
operation. `CONDA_OVERRIDE_CUDA` applies only during installation and does not
alter runtime device detection.

To repeat the stack check without a GPU, run:

```bash
docker run --rm localhost/datascience-notebook-cuda:issue84 \
  python /usr/local/bin/cuda-smoke-test.py
```

To validate GPU execution on a CDI-enabled Docker host, run:

```bash
docker run --rm --device nvidia.com/gpu=all \
  localhost/datascience-notebook-cuda:issue84 \
  python /usr/local/bin/cuda-smoke-test.py --gpu
```

The GPU check requires `torch.cuda.is_available()` and exercises CUDA matrix
multiplication and a convolution. A successful build alone does not validate
host driver compatibility or GPU execution.

## Consume the image

Pin the published digest in a private overlay:

```dockerfile
ARG BASE_CONTAINER=ghcr.io/nq-rdl/datascience-notebook-cuda:12.6@sha256:<digest>
FROM ${BASE_CONTAINER}
```

## Update dependencies

To update the lockfile, use the Pixi version pinned in the foundation image
(currently `0.70.1`):

```bash
pixi lock --manifest-path images/datascience-notebook-cuda/pixi.toml
```

Keep inherited dependency declarations aligned with
`images/scipy-notebook-ubi9/pixi.toml`. Change `cuda-version` and
`system-requirements.cuda` together when upgrading CUDA, then update the
Containerfile override and smoke-test expectation.
