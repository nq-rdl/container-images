# CI/CD Pipeline Rework: Eliminate the GHCR Cleanup Janitor

- **Date:** 2026-06-01
- **Status:** Approved (design) — pending plan + implementation
- **Branch:** `chore/review-workflow`
- **Supersedes:** Issue #36 (*feat: scheduled GHCR cleanup workflow*) and its PR — to be closed, not merged.

## 1. Problem

Issue #36 proposes a scheduled, stateful, token-privileged workflow that deletes
`sha256-*` referrer tags and orphaned untagged manifests from GHCR. It is a
**janitor that runs forever to delete garbage the pipeline generates on purpose
every day** — a downstream mop for an upstream leak.

### Evidence (live GHCR, 2026-06-01)

`bun-ubi9` package state:

| Metric | Count |
|---|---|
| Total versions | 12 |
| Tagged versions | 1 |
| Untagged orphan manifests | 11 |
| `sha256-*` referrer tags | 0 |

Two findings:

1. The `sha256-*` referrer-tag problem is **already solved** (0 found) by prior
   commits (`provenance: false`, `sbom: false`, attestation `push-to-registry:
   false`). Four prior band-aid commits fought this.
2. The remaining churn is **untagged orphan manifests** (11 vs. 1 tagged). With
   ~20 packages (each `-ubi9` image plus its stripped alias such as `bun`), all
   multi-arch, the daily rebuild orphans roughly three manifests per package per
   day → thousands of orphans per year.

### Root cause

Base images are pinned by **floating tag**, not digest:

```dockerfile
ARG UBI_VERSION=9.5
FROM registry.access.redhat.com/ubi9/ubi-minimal:${UBI_VERSION}
```

The daily build (`build.yml` → `schedule: cron '0 6 * * *'`) exists to pull
Red Hat's in-place patches to the `9.5` tag. But the build is **not
reproducible** (microdnf/curl fetch latest), so even on days when nothing
changed it produces a new digest and orphans the previous one. The
`publish-aliases` job re-points stripped aliases (`bun` → `bun-ubi9` digest)
daily too, doubling the churn.

Separately, the `ARG`-interpolated `FROM` means **Dependabot's docker updater
cannot parse the base** — the per-image Dependabot docker entries that already
exist in `.github/dependabot.yml` are effectively no-ops on the base today.

## 2. Goals / Non-goals

**Goals**

- Stop generating orphaned manifests at the source, so no scheduled cleanup is
  ever needed.
- Make the registry a deterministic projection of git: a digest is pushed only
  when a commit changes an image's inputs.
- Make the existing (currently inert) Dependabot docker config actually work.
- One-time reset of the accumulated backlog (no active consumers today).
- Close issue #36 / its PR as superseded.

**Non-goals**

- No base version bump (`9.5` → `9.6`) — separate content change.
- No removal of the empty `node-ubi9/` placeholder (correctly skipped by
  `discover` already).
- No unrelated refactors of Containerfiles or other workflows.
- No change to the attestation / SBOM / Trivy-on-build behavior (already correct).

## 3. Design principle

> The registry state is a deterministic projection of git. Nothing is pushed
> unless a commit changed the inputs. Therefore nothing needs to be cleaned up
> on a schedule.

## 4. Changes

### 4.1 Digest-pin every base image (root-cause fix)

Convert each `FROM` that references a Red Hat UBI base from an
`ARG`-interpolated floating tag to an inline, Dependabot-managed,
digest-pinned form:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:<index-digest>
```

- Keep the human-readable tag **and** append the `@sha256:` of the **manifest
  list (index) digest** so multi-arch builds keep working.
- Resolve the current index digest per base at implementation time
  (`docker buildx imagetools inspect <ref> --format '{{json .Manifest}}' | jq -r .digest`
  or `skopeo inspect --raw`).
- Multi-stage files get every `FROM` pinned. Known multi-base file: `dbt-ubi9`
  uses `ubi9/ubi-minimal` (builder), `ubi9/ubi` (rootfs), `ubi9/ubi-micro`
  (runtime).
- Remove the now-redundant `ARG UBI_VERSION` default where it only fed the
  `FROM` (verify per file; `dbt` also uses `--releasever 9`, which stays).
- The `build_matrix.arg` (runtime version, e.g. zulu/dbt version) is unrelated
  and unchanged.

### 4.2 Drop the daily build schedule

In `.github/workflows/build.yml`:

- Remove the `schedule:` trigger (`cron '0 6 * * *'`).
- Remove the `schedule`-specific branch in the `discover` step (the
  `EVENT_NAME == 'schedule'` → build-all path).

Rebuilds then fire on: push-to-main (path-filtered to `images/**` +
`build.yml`), pull_request (build-only, no push), `workflow_dispatch`, and
**merged Dependabot digest-bump PRs**. `publish-aliases` already runs only on
non-PR events, so it now re-points aliases only on real changes — daily alias
churn disappears for free.

### 4.3 Keep `trivy-scheduled-rescan.yml` unchanged

It is the correct pattern: a read-only daily CVE radar that scans `:latest` and
uploads SARIF (no registry writes, no churn). It is the safety net that surfaces
new CVEs between digest bumps. (Optional future enhancement, out of scope: open
an issue when a fixable CVE appears — noted, not implemented.)

### 4.4 One-time GHCR reset

Order chosen to avoid any window where a package is empty and to avoid touching
package visibility/settings:

1. Land all code changes and merge to `main`.
2. `workflow_dispatch` Build Images with `image=all` → pushes fresh, current,
   intentional digests for every image (tags them `latest`, version tags, etc.).
3. Verify a sample (`gh attestation verify`, tag resolution).
4. **Delete only untagged orphan versions** of this repo's packages — the
   `-ubi9` images and their stripped aliases — via
   `gh api --method DELETE /orgs/nq-rdl/packages/container/<pkg>/versions/<id>`.
   Because step 2 freshly tagged the current digests, orphan-only deletion
   cannot remove a live image.

Safety requirements for the purge:

- **Scoped allowlist**: targets derived from `images/*/` directory names plus
  their alias-stripped names (`{service}-ubi{N}` → `{service}`). Anything not in
  that set (e.g. `fhir-jit`) is never touched.
- **Dry-run first**: print every package + version id + tags that would be
  deleted; require explicit confirmation before any DELETE.
- **Fail-closed**: if a package or version can't be classified, skip it (keep).
- This is a **one-shot operational step**, delivered as a documented, dry-run-
  default script (`scripts/ghcr-purge.sh`) — it is **not** wired into CI or any
  schedule. (Whole-package deletion is available as an explicit nuclear option
  if a truly pristine registry is wanted, accepting visibility re-config.)

### 4.5 Close issue #36 and its PR

Comment explaining the root-cause fix (digest-pin + commit-driven rebuilds)
replaces the janitor, then close both as superseded.

### 4.6 Tests (TDD — written before the edits)

Fast, registry-free static assertions:

- Extend `tests/test-build-workflow-tags.sh`: assert `build.yml` has **no**
  `schedule:`/`cron` trigger, while still having `pull_request` and
  `workflow_dispatch`. Keep every existing assertion green (`provenance: false`,
  `sbom: false`, GitHub-native attest, `push-to-registry: false` ×2, no cosign,
  `imagetools create`).
- New `tests/test-base-images-pinned.sh`: for every `images/*/Containerfile`,
  every `FROM` line referencing an **external registry** base must contain
  `@sha256:` and must not use an unpinned `${...}` interpolation. Stage-to-stage
  references (`FROM <stage> AS …` / `COPY --from=<stage>`) and `FROM scratch` are
  exempt. Iterate all images so new ones are covered automatically.
- Wire the new test into a new pixi task (`policy-check-base-pinning`) and add it
  to the `policy-check` aggregate so it runs in CI and pre-commit.

### 4.7 Docs + changelog

- `CONTRIBUTING.md`: under "Containerfile conventions", replace "Pin base image
  and runtime versions via `ARG`" with digest-pin guidance (`:tag@sha256:…` so
  Dependabot manages updates). Update the "Production usage" note: tags are still
  mutable, but a rebuild is now triggered by a commit / Dependabot digest bump,
  not a daily cron.
- `README.md`: one line noting builds are digest-pinned / reproducible w.r.t. the
  base.
- `changie new` fragment (required by repo process).

## 5. Components & interfaces (isolation view)

| Unit | Contract | Independently testable by |
|---|---|---|
| Containerfiles | every base `FROM` is digest-pinned | `tests/test-base-images-pinned.sh` |
| `build.yml` | triggers = commit / PR / dispatch only (no schedule) | `tests/test-build-workflow-tags.sh` |
| `trivy-scheduled-rescan.yml` | read-only CVE radar (unchanged) | n/a (unchanged) |
| Dependabot (`dependabot.yml`) | opens base digest-bump PRs (now effective) | manual verify post-merge |
| `scripts/ghcr-purge.sh` | scoped, dry-run-default, fail-closed one-shot | dry-run output review |

## 6. Data flow (after)

```
UBI base moves
   └─> Dependabot opens digest-bump PR (weekly)
          └─> CI builds the PR (no push)
                 └─> merge → push-to-main builds+pushes that image's new digest,
                       re-points its aliases
Trivy rescan scans :latest daily (radar) — independent, no writes
Quiet weeks: zero registry writes, zero orphans.
```

## 7. Security posture & tradeoffs

- **Before:** preemptive same-day patching (rebuild every morning) at the cost of
  daily churn.
- **After:** patching is commit-driven via Dependabot (weekly cadence) plus the
  daily rescan as a CVE radar. Patch latency widens from ~hours to up to ~1 week
  (or faster via a rescan-prompted manual bump / dispatch).
- Accepted because there are no active consumers today and every registry write
  becomes auditable (tied to a reviewed commit). If tighter cadence is wanted
  later, set the Dependabot docker interval to `daily` (still no orphans — each
  bump is one commit) or add Renovate; both are out of scope here.

## 8. Rollout sequence

1. TDD red: add/extend tests → they fail.
2. Implement: digest-pin Containerfiles; remove `build.yml` schedule; add pixi
   task; docs; changie fragment → tests green; `pixi run lint-all` green.
3. Adversarial review of plan and diffs (`/codex:adversarial-review`); address
   findings.
4. PR → CI green → merge.
5. `workflow_dispatch` build-all → fresh digests.
6. Dry-run purge → confirm → delete untagged orphans.
7. Close issue #36 + PR.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Dependabot still can't bump (config/format) | Use `:tag@sha256:` inline form Dependabot supports; verify a real bump PR appears post-merge |
| Image goes stale if no bump arrives | Daily Trivy rescan surfaces CVEs; can drop Dependabot to `daily` or add a low-freq safety rebuild later |
| Many Dependabot PRs at once | Optional grouping for the docker ecosystem (follow-up, out of scope) |
| Purge deletes a live image | Build-all *before* purge; orphan-only deletion; scoped allowlist; dry-run + confirm; fail-closed |
| Removing `ARG UBI_VERSION` breaks a build | Verify each Containerfile individually; smoke-test build in CI/pre-push |
| Multi-arch base pinned to a per-arch digest | Pin the manifest-list (index) digest, not a platform child |

## 10. Out of scope

- Base `9.5` → `9.6` bump.
- Removing `node-ubi9/` placeholder.
- Rescan → auto-issue enhancement.
- Renovate / Dependabot grouping.
- Any change to `docs.yml.tmpl`, policy rego, or unrelated workflows.
