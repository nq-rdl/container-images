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

### Chained images (bake targets)

Some images are "chained": their `Containerfile` uses `ARG BASE_CONTAINER=<repo>:<tag>@sha256:<digest>`
as the base, where the base image is another image in this repo (e.g. `jamovi-ubi9` chains on
`jamovi-deps-ubi9`, which chains on `r-base-ubi9`). Chained images are built together via
`docker buildx bake` — the bake graph passes the in-flight image directly through `contexts`/`args`,
so the digest in `ARG BASE_CONTAINER` is only used when building a single image outside of bake
(e.g. a standalone `docker build`).

**Bootstrap placeholder.** A brand-new chain ships with an all-zeros digest:

```
ARG BASE_CONTAINER=ghcr.io/nq-rdl/r-base-ubi9:4.5.0@sha256:0000…0000
```

The reachability guard (`tests/test-chained-bases-reachable.sh`) recognises a GHCR
`MANIFEST_UNKNOWN` response (returned when the repo is authenticated but the tag does not
exist yet) as a **bootstrap SKIP** — the chain is new and its first publish has not happened.
The guard only fails if an authentication error, network error, or a stale/wrong digest is
found (fail-closed semantics).

**After first publish.** Once the chain's first build succeeds and the image is live on GHCR,
the all-zeros placeholder becomes stale and the guard will start failing (`MANIFEST_UNKNOWN`
transitions to `digest unreachable`). You **must** promptly run the repin script and open a
follow-up PR:

```bash
# Authenticate crane to GHCR (one-off per shell session):
echo "$GH_TOKEN" | pixi run -- crane auth login ghcr.io -u <your-github-username> --password-stdin

# Repin all chained images (or pass a specific dir):
pixi run repin-chained-bases
# or: scripts/repin-chained-base.sh images/jamovi-ubi9
```

The script resolves each chained image's published tag to its current digest, rewrites the
`ARG BASE_CONTAINER` default in the `Containerfile`, and updates the adjacent comment block.
It is idempotent (safe to re-run) and fail-closed: auth failures and network errors produce a
non-zero exit instead of silently skipping. After the script completes:

1. Run `pixi run policy-check-chained-bases-reachable` — it should PASS.
2. Add a changie fragment (`changie new`).
3. Commit and open the follow-up PR.

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

Pin by `@sha256:…` digest in production manifests. Tags are mutable — merging a
base-digest bump (or any image change) rebuilds and moves the tag to the new
digest. Rebuilds are commit-driven, not a daily cron.

### Rollback

Tags are digest-pinned in git, so rollback is a git revert:

1. `git revert <digest-bump-commit>` (or restore the previous `@sha256:` in the
   image's `Containerfile`) and merge.
2. The merge to `main` rebuilds and re-points the tag to the previous digest.
   For an immediate fix, `workflow_dispatch` **Build Images** with the specific
   `image` from the last known-good commit.

## Containerfile conventions

- Use `Containerfile`, not `Dockerfile`
- Base image must be from `registry.access.redhat.com/ubi*` or `registry.redhat.io/ubi*`
- Pin the base image by digest (`registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:…`);
  the `base-drift.yml` workflow opens a PR to bump the digest when the upstream tag moves.
  Pin runtime versions via `ARG`.
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

The same check runs in CI on every PR (`.github/workflows/changelog-check.yml`),
which the local pre-push hook cannot be made to skip from a forked PR. To skip it
for a PR that needs no entry, apply the `skip-changelog` label.

## Releasing

A release is a changelog + GitHub Release marker **for the repository**. Container
images are published continuously by `build.yml` (tagged by *service* version, e.g.
`jamovi 1.1.42`) and are **not** tied to repository releases — a `vX.Y.Z` tag never
rebuilds images.

To cut a release:

1. Make sure every change you want included has a changie fragment in
   `.changes/unreleased/` (enforced on PRs by `changelog-check.yml`).
2. Choose the next version per [SemVer](https://semver.org) and the changie kinds
   in `.changie.yaml` (`Added`/`Deprecated` → minor, `Changed`/`Removed` → major,
   `Fixed`/`Security` → patch).
3. Tag a commit that is **already on `main`** and push the tag:

   ```bash
   git tag v0.1.0 <commit-on-main>
   git push origin v0.1.0
   ```

The `release.yml` workflow then:

1. Verifies the tag points to a commit on `main` (refuses otherwise).
2. Runs `changie batch <version>` + `changie merge`, folding the unreleased
   fragments into `.changes/<version>.md` and regenerating `CHANGELOG.md`.
3. Commits the changelog to `main` and force-moves the tag onto that commit, so
   the released tag includes the generated changelog.
4. Creates a GitHub Release using `.changes/<version>.md` as the release notes.

The workflow authenticates as the `nq-rdl-release-bot` GitHub App
(`vars.RELEASE_APP_ID` + `secrets.RELEASE_APP_PRIVATE_KEY`) and skips its own
re-triggered runs (the tag-move push), so releases do not loop. The App must be
installed on this repository with write access so it can push the changelog commit
to the PR-protected `main` branch — the sibling repos (`agent-skills`,
`agent-extensions`) use the same App under the same classic branch protection, so
no ruleset bypass is required.

The changelog push is resilient to `main` advancing mid-release: it replays the
single changelog commit onto the current tip and retries, so a PR merging during
the run does not abort the release with a non-fast-forward rejection.

**Retrying a failed release.** Most transient failures are safe to retry by
re-running the failed job. If a run fails *after* it already pushed the changelog
commit to `main` (so `.changes/<version>.md` is now on `main` but the tag was not
moved), re-point the tag onto the current `main` tip and force-push it:

```bash
git fetch origin main
git tag -f v0.1.0 origin/main
git push origin v0.1.0 --force
```

The re-run checks out that commit, detects the pre-batched `.changes/<version>.md`,
skips re-batching, and just creates the release. If a fix PR added a *new* fragment
in the meantime, the workflow stops with guidance rather than overwriting the
batched file — resolve as it instructs.

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
