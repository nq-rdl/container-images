# CI/CD Pipeline Rework: Eliminate the GHCR Cleanup Janitor

- **Date:** 2026-06-01 (revised 2026-06-02 after `/codex:adversarial-review`)
- **Status:** Approved (design) — pending plan + implementation
- **Branch:** `chore/review-workflow`
- **Supersedes:** Issue #36 (*feat: scheduled GHCR cleanup workflow*) and its PR — to be closed, not merged.

## 1. Problem

Issue #36 proposes a scheduled, stateful, token-privileged workflow that deletes
`sha256-*` referrer tags and orphaned untagged manifests from GHCR. It is a
**janitor that runs forever to delete garbage the pipeline generates on purpose
every day** — a downstream mop for an upstream leak.

### Evidence (live GHCR, 2026-06-01)

`bun-ubi9`: 12 versions total — **1 tagged, 11 untagged, 0 `sha256-*`**.

1. The `sha256-*` referrer-tag problem is **already solved** (0 found) by prior
   commits (`provenance: false`, `sbom: false`, attestation `push-to-registry:
   false`). Four prior band-aid commits fought this.
2. The remaining churn is **untagged orphan manifests**. ~20 packages (each
   `-ubi9` image plus its stripped alias), all multi-arch; the daily rebuild
   orphans ~3 manifests per package per day → thousands of orphans per year.

### Root cause

Bases are pinned by **floating tag via ARG**, and builds are not reproducible:

```dockerfile
ARG UBI_VERSION=9.5
FROM registry.access.redhat.com/ubi9/ubi-minimal:${UBI_VERSION}
```

The daily build (`build.yml` → `schedule: cron '0 6 * * *'`) re-pushes a new
digest every morning even when nothing changed, orphaning the prior one;
`publish-aliases` re-points stripped aliases daily too. Separately, the
`ARG`-interpolated `FROM` means **Dependabot's docker updater cannot parse the
base** — verified: **all 11** Containerfiles use this pattern, so the existing
Dependabot docker entries bump **zero** bases today.

## 2. Goals / Non-goals

**Goals**

- Stop generating orphaned manifests at the source → no recurring scheduled
  cleanup needed.
- Make the registry change **only via merged commits** (a deterministic,
  auditable projection of git for the *base layer*).
- Replace the inert Dependabot docker config with a **FROM-aware, in-repo base
  drift-checker** that covers every stage of every image and produces zero
  registry churn.
- Strengthen the Trivy rescan into a real CVE radar now that it is the primary
  one (scan every published tag).
- One-time, reachability-safe reset of the accumulated backlog.
- Close issue #36 / its PR as superseded.

**Non-goals (explicitly deferred)**

- Auto-merge of bump PRs (human reviews/merges; documented).
- Auto-opening issues from the rescan (radar surfaces SARIF; notification is a
  later enhancement).
- RPM/pip lockfiles (build-time package determinism — see §7).
- Renovate.
- Base `9.5` → `9.6` bump; removing the empty `node-ubi9/` placeholder;
  unrelated refactors of `docs.yml.tmpl`, policy rego, or other workflows.

## 3. Design principle

> The registry's **base layer** is a deterministic projection of git: a digest
> is pushed only when a merged commit changes an image's inputs. Build-time
> package managers (`microdnf`, `pip`, downloaded binaries) are **not** locked,
> so the image is reproducible w.r.t. the pinned base but not bit-for-bit
> overall — see §7 for the consequences and the non-base remediation path.

Some orphan accumulation is inherent to mutable tags (moving `latest` to a new
digest always orphans the prior target). The goal is not literally zero
orphans; it is to drop the rate from **daily/autonomous** to
**per-real-change/git-traceable**, low enough that no scheduled janitor is
needed and any future prune is a rare, manual, reachability-safe operation.

## 4. Changes

### 4.1 Digest-pin every base image (root-cause fix)

For every `FROM` that references an **external registry** (UBI bases *and*
`golang` in spark-operator's builder stage), convert from ARG-interpolated
floating tag to an inline, digest-pinned form:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:<index-digest>
```

- Append the `@sha256:` of the **manifest-list (index) digest** so multi-arch
  builds keep working. Resolve per base at implementation time (`crane digest
  <ref>:<tag>` returns the index digest).
- Pin **every** `FROM` in multi-stage files. Known: `dbt` (`ubi-minimal`
  builder, `ubi` rootfs, `ubi-micro` runtime); `spark-operator` (`golang`
  builder, `ubi-minimal` runtime).
- Remove the now-redundant `ARG UBI_VERSION`/`ARG GO_VERSION` defaults where they
  only fed `FROM` (verify per file; `dbt`'s `--releasever 9` stays). Runtime
  `build_matrix.arg` values (zulu/dbt/python versions) are unrelated and
  unchanged.

### 4.2 Drop the daily build schedule; scope alias publishing

In `.github/workflows/build.yml`:

- Remove the `schedule:` trigger (`cron '0 6 * * *'`) and the
  `EVENT_NAME == 'schedule'` build-all branch in `discover`.
- Scope `publish-aliases` to the images in the triggering build matrix instead
  of looping all `images/*/`. (Efficiency, not a churn fix — `imagetools create`
  is content-addressed, so unchanged aliases already produce no new version.)

Rebuilds then fire only on: push-to-main (path-filtered), PR (build-only, no
push), `workflow_dispatch`, and **merged base-bump PRs** from the drift-checker.

### 4.3 Strengthen the Trivy rescan (now the primary CVE radar)

`trivy-scheduled-rescan.yml`: expand the matrix to scan **every published tag**
derived from each `image.yaml` (e.g. python `3.11` *and* `3.12`/`latest`), not
just `:latest`. Keep `exit-code: '0'` and SARIF upload (`if: always()`) so a
finding never kills the radar. (Auto-issue notification deferred — §2.)

### 4.4 In-repo base drift-checker (the bump mechanism)

New scheduled workflow `.github/workflows/base-drift.yml` (replaces the removed
Dependabot docker entries):

- Parse **every** `FROM <ref>:<tag>@sha256:<digest>` across `images/*/Containerfile`.
- For each, resolve the live index digest of `<ref>:<tag>` (`crane digest`).
- If it differs from the pinned `<digest>`, update the `FROM` line and open (or
  update) a single bump PR per image (`peter-evans/create-pull-request` or `gh`).
- **Zero registry writes** — it only edits files and opens PRs. The registry
  still changes solely when a human merges the PR (→ build-on-merge).
- Also remove the 10 `package-ecosystem: docker` blocks from
  `.github/dependabot.yml`; keep the `github-actions` block.

### 4.5 One-time GHCR reset (reachability-safe)

Order avoids any empty-package window and never deletes a live manifest:

1. Land all code changes; merge to `main`.
2. `workflow_dispatch` Build Images `image=all` → push fresh current digests.
3. Verify a sample (`gh attestation verify`, tag resolution, multi-arch pull).
4. **Reachability-safe purge** via `scripts/ghcr-purge.sh` (new):
   - Build a **keep-set** = every tagged version's digest **plus every child
     manifest** referenced by each tagged index (resolve indexes with
     `crane manifest`/`skopeo`).
   - Delete only versions whose digest is **not** in the keep-set.
   - **Scoped allowlist** to this repo's packages (`images/*/` names + their
     `{service}-ubi{N}`→`{service}` aliases); never touch others (e.g.
     `fhir-jit`).
   - **Dry-run default**: print package, version id, digest, tags, and
     keep/delete reason; require explicit confirmation before any DELETE.
   - **Fail-closed**: any version that can't be classified (index unresolvable)
     is kept.
   - One-shot operational script — **not** wired into CI or any schedule.

### 4.6 Close issue #36 and its PR

Comment explaining the root-cause fix replaces the janitor; close both as
superseded.

### 4.7 Tests (TDD — written before the edits)

**Fast, registry-free static assertions** (run in pre-commit + CI):

- Extend `tests/test-build-workflow-tags.sh`: assert `build.yml` has **no**
  `schedule`/`cron` trigger; still has `pull_request` + `workflow_dispatch`.
  Keep all existing assertions green.
- New `tests/test-base-images-pinned.sh`: for every `images/*/Containerfile`,
  every `FROM` referencing an **external registry** contains `@sha256:` and no
  unpinned `${...}`. Stage refs (`FROM <stage> AS …`, `COPY --from=`) and
  `FROM scratch` are exempt. Iterates all images so new ones are covered.
- New pixi task `policy-check-base-pinning`, added to the `policy-check`
  aggregate.

**Registry-backed validation** (CI job on PR, network available):

- `validate-base-pins`: for each pinned `<ref>@<digest>`, assert
  `crane manifest` resolves to an **index** whose `.manifests[].platform` set
  includes every platform declared in that image's `image.yaml`. Required PR
  check. (Closes finding #7 — a single-arch pin would pass the static test but
  break the arm64 push.)

**Drift-checker self-test**: a `bash -n` + unit check that the parser detects a
drifted vs. up-to-date pinned digest on fixtures (one current, one stale, one
malformed → kept).

### 4.8 Docs + changelog

- `CONTRIBUTING.md`: replace "Pin base image and runtime versions via `ARG`"
  with digest-pin guidance (`:tag@sha256:…`, bumped by the drift-checker PR).
  Update "Production usage": a rebuild is triggered by a merged commit / drift
  PR, not a daily cron. Add a **Rollback** subsection: revert the digest-bump
  commit and `workflow_dispatch` a rebuild of the last known-good SHA.
- `README.md`: one line noting builds are digest-pinned w.r.t. the base.
- `changie new` fragment (required by repo process).

## 5. Components & interfaces (isolation view)

| Unit | Contract | Tested by |
|---|---|---|
| Containerfiles | every external base `FROM` is index-digest-pinned | `test-base-images-pinned.sh` + `validate-base-pins` |
| `build.yml` | triggers = commit / PR / dispatch only; aliases scoped to matrix | `test-build-workflow-tags.sh` |
| `trivy-scheduled-rescan.yml` | scans every published tag; read-only radar | matrix derived from `image.yaml` |
| `base-drift.yml` | drift → bump PR; zero registry writes | drift-checker self-test |
| `scripts/ghcr-purge.sh` | keep-set (tagged + children); scoped; dry-run; fail-closed | dry-run output review |
| `dependabot.yml` | github-actions only (docker entries removed) | n/a |

## 6. Data flow (after)

```
Base index digest moves
   └─> base-drift.yml (scheduled) opens a per-image bump PR (no registry write)
          └─> human reviews + merges
                 └─> push-to-main builds+pushes that image's new digest,
                       re-points its (matrix-scoped) aliases
Trivy rescan scans EVERY published tag daily (radar) — independent, no writes
Quiet days: zero registry writes, zero new orphans.
```

## 7. Security posture & tradeoffs (honest)

- **Before:** the daily rebuild preemptively refreshed *everything* — base, RPMs
  (`microdnf`), pip deps, downloaded binaries — at the cost of daily churn.
- **After:** the **base** is refreshed via drift PRs (commit-driven). Build-time
  packages (RPM/pip/binaries) are **not** auto-refreshed and are **not** locked,
  so a CVE fixed only in an RPM/PyPI dep will **not** move the base digest and
  will **not** trigger a drift PR.
- **Radar + remediation:** the daily Trivy rescan (now scanning every tag) is the
  detection path for *all* CVEs incl. non-base ones; remediation for a non-base
  finding is a `workflow_dispatch` rebuild (re-pulls latest RPM/pip), or a normal
  commit. **Rollback:** revert the digest-bump commit + dispatch a rebuild of the
  last known-good SHA.
- Accepted because there are no active consumers today and every registry write
  becomes tied to a reviewed commit. Tighter cadence later = drift-checker on a
  shorter cron, RPM/pip lockfiles, or auto-merge — all deferred (§2).

## 8. Rollout sequence

1. TDD red: add/extend `test-base-images-pinned.sh`, `test-build-workflow-tags.sh`
   schedule assertion, drift-checker self-test → fail.
2. Implement: digest-pin all Containerfiles; remove `build.yml` schedule + scope
   aliases; expand rescan matrix; add `base-drift.yml`; trim `dependabot.yml`;
   `ghcr-purge.sh`; docs; changie → static tests + `pixi run lint-all` green.
3. Adversarial review of the diffs (`/codex:adversarial-review`); address.
4. PR → CI green (incl. `validate-base-pins`) → merge.
5. `workflow_dispatch` build-all → fresh digests; verify multi-arch pulls.
6. `ghcr-purge.sh` dry-run → confirm → reachability-safe delete.
7. Close issue #36 + PR.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Purge deletes a live multi-arch child | Keep-set = tagged digests **+ referenced children**; build-all before purge; dry-run + confirm; fail-closed |
| Drift-checker misses a FROM (multi-stage) | Parser iterates **all** FROMs; self-test on fixtures; `validate-base-pins` ensures every pinned digest is a valid index |
| Single-arch digest pinned by mistake | `validate-base-pins` required PR check asserts index covers all `image.yaml` platforms |
| Non-base CVE never triggers rebuild | Rescan scans every tag (radar) → dispatch rebuild (remediation); documented |
| Image goes stale if a drift PR sits unmerged | Reviewer ownership (CODEOWNERS) — noted follow-up; auto-merge deferred |
| Removing `ARG UBI_VERSION` breaks a build | Verify each Containerfile; PR build + smoke test |
| `golang` builder base unpinned | Treated as an external base — pinned and drift-tracked like UBI |

## 10. Out of scope

Auto-merge; rescan auto-issue notifications; RPM/pip lockfiles; Renovate;
Dependabot PR grouping; base `9.5`→`9.6`; removing `node-ubi9/`; changes to
`docs.yml.tmpl`, policy rego, or unrelated workflows.
