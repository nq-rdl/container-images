# Design: Issue #45 — Repin scipy-notebook chained base + reachability guard

- **Date:** 2026-06-07
- **Issue:** #45 (post-merge follow-up from #44; umbrella #30, phase 2)
- **Branch:** `fix/scipy-repin-base-digest` (cut from `origin/main` @ `9817207`)
- **Reviewers consulted:** interactive (user), `codex:rescue` adversarial review

## Problem

`images/scipy-notebook-ubi9/Containerfile:15` pins its parent via a **placeholder
digest** taken from a *locally-built* `minimal-notebook-ubi9` image:

```dockerfile
ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:640ebba9ab2959fd6489f0b0e30b0434bfa5b3308b9e478ee766e1546e448834
```

The placeholder existed because of a chicken-and-egg: `minimal-notebook-ubi9` did
not exist in GHCR until #44 merged and the `bake` job published it. As of
2026-06-07 #44 is merged (`9817207`) and the bake run (`27082627036`) completed
successfully, so the real digest is now resolvable:

```
ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0
  -> sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184
```

`docker-bake.hcl` overrides `BASE_CONTAINER` to the in-graph `minimal-notebook`
target, so **CI bake builds are unaffected**. Only a standalone
`docker build images/scipy-notebook-ubi9` pulls the placeholder and fails with
`manifest unknown`.

### The deeper gap

`tests/test-chained-bases-pinned.sh` validates only the digest **format**
(`ghcr.io/nq-rdl/<name>:<tag>@sha256:<64-hex>`). The placeholder matches that
regex, so `pixi run policy-check` is **green with the wrong digest**. The real
failure mode (reachability) is covered by **no test**. A plain one-line repin
therefore has no genuine TDD red state and leaves the blind spot open for the
next chained image.

## Goals

1. Repin `Containerfile:15` to the authoritative published digest.
2. Add a real red→green test asserting chained `ARG BASE_CONTAINER` pins
   **resolve in GHCR and cover declared platforms** — a permanent regression
   guard against placeholder/stale chained pins.
3. Wire that check into CI so future occurrences are caught automatically.

## Non-goals

- No change to the bake graph, build matrix, or external-base (`FROM @sha256:`)
  validation in `test-base-images-pinned.sh` / the existing `FROM`-loop in
  `validate-base-pins.yml`.
- No multi-arch expansion: the datascience chain is `linux/amd64`-only by design.

## Decisions (with rationale)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Add a TDD **reachability** test, not just a repin | Existing tests are format-only; placeholder stays green. Reachability gives a true RED (confirmed: `manifest unknown`) → GREEN. |
| D2 | Standardize on **`crane`**, added to pixi deps | CI parity (`validate-base-pins.yml` already uses crane); crane is on conda-forge (0.21.6) → reproducible across all pixi platforms; single code path (no crane‖skopeo branching). |
| D3 | Assert **reachability + platform coverage** | Matches the existing external-pin contract (index covers `image.yaml` platforms); catches an arch-mismatched pin, not just a missing one. |
| D4 | **Error-class-specific** skip | Only a clear absent-tag (`MANIFEST_UNKNOWN`/404) on the **tag** skips (bootstrap). Pinned-digest-unreachable while tag exists → FAIL. Auth/rate-limit/DNS/network → FAIL (fail-closed). Prevents the skip becoming a silent bypass. |
| D5 | Reachability, **not equality** with current tag digest | Intentional pin-to-an-older-digest must still pass; we verify the pinned manifest is alive, not that it floats with the tag. |
| D6 | New pixi task **excluded** from default `policy-check` | Keeps the default offline `policy-check` fast and hermetic; the registry-aware task is opt-in locally and runs in CI. |
| D7 | CI home = **`validate-base-pins.yml`** | Already has crane + yq + the platform list; conceptually the "are pins valid?" workflow. Separate ARG parser path (the `FROM` loop never sees `FROM ${BASE_CONTAINER}`). |

## Components

### 1. Repin (the core of #45)

`images/scipy-notebook-ubi9/Containerfile:15`:

```diff
-ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:640ebba9ab2959fd6489f0b0e30b0434bfa5b3308b9e478ee766e1546e448834
+ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184
```

The explanatory comment block above the ARG is updated to drop the
"placeholder/replace after publish" wording now that it is reconciled.

### 2. `tests/test-chained-bases-reachable.sh`

For each `images/*/Containerfile` declaring `ARG BASE_CONTAINER=`:

1. Extract the last `ARG BASE_CONTAINER=` default; parse `repo:tag@sha256:<d>`.
2. Normalize for crane: `repo:tag@digest` → `repo@digest` (crane rejects the
   `repo:tag@digest` form — reuse the proven normalization from
   `validate-base-pins.yml`).
3. Read declared platforms from the sibling `image.yaml` (default
   `["linux/amd64"]`).
4. **Tag-existence probe:** `crane manifest repo:tag`.
   - Fails specifically with absent-tag/`MANIFEST_UNKNOWN`/404 → **SKIP**
     (bootstrap; image not published yet).
   - Fails any other way → **FAIL** (fail-closed).
5. **Pinned-digest probe:** `crane manifest repo@digest`.
   - Fails → **FAIL** (placeholder/stale pin).
6. **Platform coverage:** the resolved manifest is a non-empty image index that
   covers every declared platform → else **FAIL**.
7. If no `crane` binary is present at all (offline dev) → **SKIP** with a loud
   notice (never silently pass).

Exit non-zero if any chained pin FAILs.

### 3. Wiring

- **`pyproject.toml`**: add `crane = "*"` to `[tool.pixi.dependencies]`; add task
  `policy-check-chained-bases-reachable = "bash tests/test-chained-bases-reachable.sh"`.
  **Not** added to the `[tool.pixi.tasks.policy-check] depends-on` list (D6).
- **`.github/workflows/validate-base-pins.yml`**: add a step running the script
  (crane already installed via `imjasonh/setup-crane`); extend `on.*.paths` to
  include `tests/**` and `pyproject.toml` so script/task changes trigger it.

### 4. Changelog

A `changie` `Fixed` fragment:

> Repin scipy-notebook-ubi9 BASE_CONTAINER to the published minimal-notebook-ubi9
> digest; add a CI guard that chained base pins resolve in GHCR.

## Test strategy (TDD)

| Step | State | Evidence |
|------|-------|----------|
| Write `test-chained-bases-reachable.sh`, run against current tree | **RED** | scipy pin `640ebba9…` → `manifest unknown` while tag exists → FAIL (confirmed via skopeo probe) |
| Repin `Containerfile:15` to `46e14db9…` | **GREEN** | digest resolves; index covers `linux/amd64` → PASS |
| `pixi run policy-check` | green | format check still passes (regression: nothing broken) |
| `pixi run policy-check-chained-bases-reachable` | green | new guard passes |
| CI `validate-base-pins.yml` on the PR | green | crane step passes against published GHCR |

## Acceptance criteria

- `Containerfile:15` digest **equals** `sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184` (one-off, verified at review — the permanent test is reachability-based by D5).
- `test-chained-bases-reachable.sh` is RED before the repin, GREEN after.
- `pixi run policy-check` and `pixi run policy-check-chained-bases-reachable` both pass.
- `validate-base-pins.yml` is green on the PR.
- A `changie` fragment is present.

## Risks / failure modes

- **CI registry flakiness** (auth/rate-limit/network): mitigated by D4 — these
  fail-closed rather than skip, but they fail the *new step*, not the build. The
  workflow already pulls public GHCR anonymously; rate limits are unlikely for a
  handful of `crane manifest` calls.
- **crane version drift** between pixi (0.21.6) and CI (`setup-crane@v0.6`):
  acceptable — only `crane manifest` is used; output contract is stable.
- **Over-engineering for a one-line issue:** accepted deliberately — the guard
  closes a confirmed blind spot (Codex finding #8) and prevents the exact
  recurrence #45 represents.

## Execution flow

writing-plans → subagent-driven-development, each task TDD (red → green →
refactor), then `requesting-code-review` before the PR.

## Addendum (execution): whole-chain reconcile

On its first run, the new reachability guard surfaced that the placeholder
problem was **not unique to scipy** — the entire chain needed reconciling:

| Source → parent | Was pinned | State | Repinned to |
|---|---|---|---|
| scipy → minimal | `640ebba9` | placeholder (unreachable) | `46e14db966` |
| base-notebook → foundation | `40eb4a7a` | placeholder (**unreachable**) | `cd76a341` |
| minimal → base-notebook | `34a77143` | reachable but **stale** (orphaned non-tag digest; GC-risk) | `86e8ef3d` |

With user approval, the PR was expanded from "repin scipy" to reconciling all
three chained bases to their current published GHCR digests. This is the guard
working as intended: it converted a silent, latent multi-image breakage into a
visible signal on the first run. The `minimal` pin passed reachability (D5) but
was repinned anyway because its old digest is not tag-referenced and would break
standalone builds if garbage-collected.
