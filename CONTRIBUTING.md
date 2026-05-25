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

## Containerfile conventions

- Use `Containerfile`, not `Dockerfile`
- Base image must be from `registry.access.redhat.com/ubi*` or `registry.redhat.io/ubi*`
- Pin base image and runtime versions via `ARG`
- Include OCI labels: `org.opencontainers.image.title`, `.description`, `.source`, `.vendor`, `.licenses`
- End with a non-root `USER` (UID 1001, GID 0 for OpenShift compatibility)
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
