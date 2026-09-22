# Pixi on UBI9

This image provides Pixi 0.74.0 on Red Hat Universal Base Image (UBI) 9 minimal.
It supports `linux/amd64` and `linux/arm64` with checksum-verified Pixi binaries.
The image contains no project environment. Downstream images install dependencies from their own manifests and lockfiles.

The default user is `1001:0`, with writable home and workspace directories.
The working directory is `/workspace`. The default command is `pixi --help`.

## Building and checking the image

To build from the repository root, run:

```bash
docker build -f images/pixi-ubi9/Containerfile -t ghcr.io/nq-rdl/pixi-ubi9:0.74.0 images/pixi-ubi9
docker run --rm ghcr.io/nq-rdl/pixi-ubi9:0.74.0 pixi --version
```

The existing image discovery workflow publishes this image after merge to `main`.
Published tags are `0.74.0`, `0.74`, and `latest`.

## Installing a downstream environment

Use the image as a build stage and copy the locked environment into a UBI runtime stage.
Keep the environment at the same absolute path in both stages.
Pin the published base by digest for production builds.

```dockerfile
FROM ghcr.io/nq-rdl/pixi-ubi9:0.74.0 AS builder
USER 0
WORKDIR /app
COPY pyproject.toml pixi.lock ./
RUN pixi install --locked --environment runtime
```

The example requires a `runtime` environment in the downstream manifest.
Update both architecture checksums when changing `PIXI_VERSION`.
