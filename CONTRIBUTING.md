# Contributing

## Prerequisites

- [pixi](https://pixi.sh) — manages all dev tooling
- `podman` or `docker` with buildx

## Getting started

```bash
pixi install
pixi run pre-commit-install
```

## Adding a new image

1. Create `images/<name>/` with:
   - `Containerfile` — must use a UBI base image
   - `image.yaml` — metadata (owners, platforms, tags, support status)
   - `README.md` — image-specific docs
2. Add a `docker` entry in `.github/dependabot.yml`
3. Run `pixi run lint-all` to validate
4. Open a PR

## Image naming convention

Images follow the pattern `{service}-ubi{major}:{service_version}`.

### Image names

The image name encodes the service and the UBI major version:

```
ghcr.io/nq-rdl/{service}-ubi{major}
```

When a new UBI major version ships (e.g., UBI 10), a new image is created
(`{service}-ubi10`). The previous image continues receiving patches until EOL.

A convenience image without the UBI suffix (`{service}`) tracks the latest
UBI major version and is suitable for local development only (planned — see
[#7](https://github.com/nq-rdl/container-images/issues/7)).

### Tags

| Tag | Meaning |
|-----|---------|
| `{version}` | Specific service version, latest UBI patch (e.g., `1.1.42`) |
| `{major.minor}` | Latest patch of that minor (e.g., `1.1`) |
| `latest` | Latest service version, latest UBI patch |

### Tag semantics by image variant

| Reference | Service version | UBI major |
|-----------|----------------|-----------|
| `{service}-ubi{major}:{version}` | Pinned | Pinned |
| `{service}-ubi{major}:latest` | Latest | Pinned |
| `{service}:{version}` | Pinned | Latest |
| `{service}:latest` | Latest | Latest |

### Production usage

Pin by `@sha256:…` digest in production manifests. Tags are mutable — a UBI
security rebuild updates the image behind the same tag.

## Containerfile conventions

- Use `Containerfile`, not `Dockerfile`
- Base image must be from `registry.access.redhat.com/ubi*` or `registry.redhat.io/ubi*`
- Pin base image and runtime versions via `ARG`
- Include OCI labels: `org.opencontainers.image.title`, `.description`, `.source`, `.vendor`, `.licenses`
- Consider using a non-root `USER` where the application supports it
- Clean up package caches (`microdnf clean all`)

## Local checks

```bash
pixi run lint-all            # hadolint + shellcheck + actionlint + conftest
pixi run policy-check        # OPA/Conftest policies only
pixi run lint-containerfiles # hadolint only
pixi run pre-commit-run      # all pre-commit hooks
```

## Pre-commit hooks

Pre-commit runs automatically on `git commit` after `pixi run pre-commit-install`. Hooks include: hadolint, shellcheck, actionlint, gitleaks, conftest policy checks, trailing whitespace, and end-of-file fixer.
