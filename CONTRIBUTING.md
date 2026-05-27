# Contributing

## Prerequisites

- [pixi](https://pixi.sh) — manages all dev tooling
- `podman` or `docker` with buildx — container builds and smoke tests
- [k3d](https://k3d.io) — lightweight Kubernetes for local smoke tests
- `kubectl` — interacts with k3d clusters during smoke tests

Install everything in one shot:

```bash
make install-deps
```

## Getting started

```bash
make install-deps                # install pixi, container runtime, k3d, kubectl
pixi install
pixi run pre-commit install --hook-type pre-commit --hook-type pre-push
```

## Adding a new image

1. Create `images/<name>/` with:
   - `Containerfile` — must use a UBI base image
   - `image.yaml` — metadata (owners, platforms, tags, support status)
   - `README.md` — image-specific docs
   - `smoke-cmd` — (optional) single line of args passed to the container
     during smoke tests (e.g., `--version`). Without this file the default
     `ENTRYPOINT`/`CMD` is used.
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
UBI major version and is suitable for local development only.

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
- Set `org.opencontainers.image.vendor` to `"Research Data Laboratory"` — this value must be consistent across all images
- Consider using a non-root `USER` where the application supports it
- Clean up package caches (`microdnf clean all`)

## Local checks

```bash
pixi run lint-all                  # hadolint + shellcheck + actionlint + all policies
pixi run policy-check              # all OPA/Conftest policies + workflow tag checks
pixi run policy-check-containerfiles # Containerfile policies only
pixi run policy-check-image-meta   # image.yaml tag convention checks
pixi run policy-check-workflow-tags # build workflow tag compliance
pixi run lint-containerfiles       # hadolint only
pixi run pre-commit-run            # all pre-commit hooks
pixi run trivy-scan                # Trivy vulnerability scan (CRITICAL/HIGH)
pixi run smoke-test                # build all images + k3d cluster test
```

## Changelog

Every PR must include a changie fragment describing the change.
[Install changie](https://changie.dev/guide/installation/) (`brew install changie`
or `go install github.com/miniscruff/changie@latest`), then run:

```bash
changie new
```

A soft reminder appears on `git commit` if no fragment exists. On `git push`, the
check is enforced — pushes are blocked until a fragment is added. If a PR genuinely
needs no changelog entry, bypass with `SKIP_CHANGELOG=1 git push`.

## Smoke tests

On `git push`, a smoke test runs automatically (via pre-commit pre-push hook)
that:

1. **Builds every image** under `images/` with your container runtime
   (docker or podman)
2. **Runs each image** with `docker`/`podman run` to verify it starts
   correctly outside Kubernetes
3. **Creates a temporary k3d cluster**, imports the built images, and verifies
   each one starts as a pod

If an image directory contains a `smoke-cmd` file, its first line is passed
as arguments to the container in phases 2 and 3 (e.g., `--version` or
`spark-submit --version`). Without this file the default `ENTRYPOINT`/`CMD`
is used.

To run manually:

```bash
scripts/smoke-test.sh
```

To bypass on a push (e.g., docs-only change):

```bash
SKIP_SMOKE=1 git push
```

## Trivy vulnerability scan

A Trivy scan runs on `git push` (via pre-push hook) after the smoke test.
It checks every image under `images/` for fixable **CRITICAL** and **HIGH**
severity vulnerabilities — the same severity filter and `ignore-unfixed`
setting used by CI in `build.yml`. Unlike CI (which uploads SARIF results
without blocking), the local hook **blocks the push** when fixable
vulnerabilities are found so they can be addressed before review.

Images are reused from the smoke-test build cache when available; otherwise
Trivy builds them first.

To run manually:

```bash
scripts/trivy-scan.sh
```

To bypass on a push:

```bash
SKIP_TRIVY=1 git push
```

## Pre-commit hooks

Pre-commit runs automatically on `git commit` and `git push` after hook
installation. Hooks include: hadolint, shellcheck, actionlint, gitleaks, conftest
policy checks, changie fragment check, smoke tests, trailing whitespace, and
end-of-file fixer.

| Hook | Stage |
|------|-------|
| trailing-whitespace | commit |
| end-of-file-fixer | commit |
| check-yaml | commit |
| check-merge-conflict | commit |
| gitleaks | commit |
| hadolint | commit |
| shellcheck | commit |
| actionlint | commit |
| conftest | commit |
| changie fragment reminder | commit |
| changie fragment required | push |
| smoke test (build + container run + k3d) | push |
| trivy vulnerability scan | push |
