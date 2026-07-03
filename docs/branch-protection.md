# Branch protection: required status checks on `main`

`main`'s branch protection requires an approving review and conversation resolution. This page
records which CI checks should also gate `main` as **required status checks**, why the others are
deliberately left optional, and how to apply the setting. It is the companion to
[`releasing.md`](releasing.md), which owns the release-flow-specific settings.

Required status checks are a GitHub **repo setting**, not a repo artifact — there is no ruleset
file that owns them. This page is the source of truth an admin applies by hand.

## The trap: only *always-run* checks may be required

Requiring a check that never reports on a given PR leaves that PR stuck forever at *"Expected —
Waiting for status to be reported."* The failure mode depends on **how** a check goes absent:

- **Workflow-level `paths:` filter → no check is created → PR hangs if required.** A PR that
  touches none of the filtered paths never triggers the workflow, so GitHub never sees a check of
  that name.
- **Job-level `if:` skip → a `skipped` check *is* created → counts as passing.** The workflow
  triggers, the job is skipped, and branch protection treats a `skipped` required check as a pass.

## Required checks

Mark these **always-run** checks (no workflow `paths:` filter) as required on `main`:

| Required check (job `name:` / id) | Workflow            |
| --------------------------------- | ------------------- |
| `actionlint`                      | `lint.yml`          |
| `shellcheck`                      | `lint.yml`          |
| `gitleaks`                        | `lint.yml`          |
| `version-monotonic`               | `release-pr-guard.yml` |

`version-monotonic` is a release-flow guard (see [`releasing.md`](releasing.md)): it is skipped on
non-`release/v*` PRs, and a skipped required check counts as a pass, so requiring it is safe on
every PR while making a stale release PR unmergeable. It is listed here so the two pages agree and
so the apply command below (which rewrites the *entire* required set) does not drop it.

## Deliberately *not* required

| Check                    | Workflow                | Why not required                                                                                                 |
| ------------------------ | ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| Build Images jobs        | `build.yml`             | **Workflow-level `paths: ['images/**', …]` filter.** A PR touching no image produces **no check** — requiring it would hang. |
| `hadolint`               | `hadolint.yml`          | `paths: ['images/**/Containerfile']` — same path-filter trap.                                                    |
| OPA policy jobs          | `policy.yml`            | `paths: ['images/**', 'policy/**', …]` — same trap.                                                              |
| Validate Base Pins       | `validate-base-pins.yml`| `paths: ['images/**', …]` — same trap.                                                                           |
| `check-changie-fragment` | `changelog-check.yml`   | Job-level `if:` skips on `skip-changelog` / dependabot. It reports `skipped` = pass, so requiring it is harmless but pointless. |

## Applying the setting

Prefer a `PATCH` to the granular `required_status_checks` sub-resource over a full
`PUT .../protection` (which would replace the *entire* config). The `PATCH` leaves the review and
conversation-resolution rules untouched. Branch protection must already exist on `main`, or the
`PATCH` 404s.

!!! warning "The `checks` array replaces the entire required-check set"
    The `checks` you send **become** the required-check list — the `PATCH` is not additive, so any
    check you omit is **dropped**. The snippet below therefore lists `version-monotonic` too;
    leaving it out would silently un-require it and make stale release PRs mergeable again. The
    GitHub **UI** path is additive by contrast — ticking a box adds a check without removing the
    others.

Via the API (`gh` or `curl`, needs repo-admin):

```bash
gh api -X PATCH \
  repos/nq-rdl/container-images/branches/main/protection/required_status_checks \
  -f 'checks[][context]=actionlint' \
  -f 'checks[][context]=shellcheck' \
  -f 'checks[][context]=gitleaks' \
  -f 'checks[][context]=version-monotonic'   # release-flow guard (releasing.md) — omit and it is dropped
```

To also require branches to be up to date before merging (which
[`releasing.md`](releasing.md#repo-settings-prerequisites-one-time) wants **on** so the
`version-monotonic` guard stays binding against a moving base), add a **typed** boolean
(`gh api` needs `-F`, not `-f`): `-F 'strict=true'`. Weigh the rebase friction this adds to every
PR before enabling it.

## Maintenance: names are coupled to the workflows

A required status check is matched by the **exact job `name:`** string. Renaming a job (or dropping
its `name:`) silently drops the requirement — the old name stops reporting, the new name is not
required, and the gate quietly disappears while still showing green. When you rename, add, or
remove an always-run job, update this page's [required-checks table](#required-checks) **and** the
required status checks on `main` to match.
