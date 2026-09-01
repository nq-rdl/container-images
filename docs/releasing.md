# Releasing

This is the runbook for cutting a repository release of `container-images`. A release is a
changelog + GitHub Release marker **for the repository**; it does not rebuild or re-tag
container images (those are published continuously by `build.yml`, tagged by *service* version).

Releases are cut through a reviewable pull request — never by pushing a `v*` tag locally.
`VERSION` is the single version source. Three workflows drive the flow:

- **Release — Prepare PR** (`.github/workflows/release-prepare.yml`, `workflow_dispatch`) — opens
  a `release/v<version>` PR.
- **Release — PR guard** (`.github/workflows/release-pr-guard.yml`, `pull_request` on `main`) —
  fails a release PR whose content does not match its branch name, or whose version is not
  strictly greater than `main`'s `VERSION` (a stale PR).
- **Release — Finalize on merge** (`.github/workflows/release-finalize.yml`, `pull_request:
  closed` on `main`) — tags and publishes once that PR is merged.

One supporting workflow keeps the tooling honest:

- **Changie pin check** (`.github/workflows/changie-pin-check.yml`, weekly `schedule` +
  `workflow_dispatch`) — opens a tracking issue when the Changie version pinned in the prepare
  workflow falls behind upstream. It never edits the repository; see
  [Pinned Changie](#pinned-changie).

## Cutting a release

1. Go to the repo's **Actions** tab → **"Release — Prepare PR"** → **Run workflow**.
2. Enter the `version` input as `X.Y.Z` — no leading `v`, no zero-padded components (`0.1.0` is
   accepted; `v0.1.0` and `1.0.00` are rejected) — and run it. It must be strictly greater than
   the current `VERSION`.
3. The workflow batches the changie changelog, stamps `VERSION` (and `pyproject.toml`), and opens
   a `release/v<version>` PR labelled `skip-changelog`, authored via the GitHub App token so the
   PR's own CI runs on it.
4. Review the PR diff. Expect: `CHANGELOG.md` and a new `.changes/<version>.md` added, the
   `.changes/unreleased/` fragments consumed (removed), and `VERSION` + `pyproject.toml` bumped
   to the new version.
5. Squash-merge the PR once it's green and approved. Merging **is** the release gate — branch
   protection controls who is allowed to do this.
6. On merge, **"Release — Finalize on merge"** tags `v<version>` on the squash-merge commit and
   publishes the GitHub Release from `.changes/<version>.md`.

Preconditions enforced by the prepare workflow: the version must be canonical SemVer (below) and
monotonically greater than the current `VERSION`; no existing `v<version>` tag,
`release/v<version>` branch, or already-batched `.changes/<version>.md` may be present; and there
must be unreleased changie fragments to batch. The finalize workflow re-asserts monotonicity at
the publish point: it refuses to tag a version at or below the newest existing `v*` tag, so
merging two open release PRs out of order fails closed instead of publishing a downgrade. The
pre-merge **"Release — PR guard"** runs on every same-repo `release/v*` PR and fails when the PR's
version is not strictly greater than `main`'s current `VERSION` — catching a stale release PR
*before* its downgraded `VERSION` can land on `main` (see the required-check prerequisite below for
what makes this binding). The guard also fails when the branch's content does not match its name —
`VERSION` must equal the branch's version and `.changes/<version>.md` must exist — the same
consistency checks finalize re-asserts on the merge commit.

**Same-repo branches only.** Both the guard and finalize act only on `release/v*` branches that
live in this repository — the ones Prepare creates. A PR from a fork whose head happens to be named
`release/v*` is skipped by both: it is never guarded (branch protection counts the skipped required
check as passing) and never finalized on merge — no tag, no release. Do not merge one as a release;
cut releases only through Prepare.

**Canonical versions only.** All three workflows apply the same rule to the version — each
component a plain integer with no leading zeros — because GNU `sort -V` orders `0.1.00` *after*
`0.1.0`. A zero-padded version would otherwise pass every monotonic check and publish a
non-SemVer tag for a number that has already shipped. Prepare rejects it at the input, the guard
rejects a hand-made `release/v1.0.00` branch, and finalize re-checks the branch name before
tagging even when it is the only guard that ran.

**Fail-closed probes.** Every remote lookup in these workflows (`git ls-remote` for tags and
branches, `gh release view` for releases) distinguishes "absent" from "errored". A transient API
failure stops the run instead of being read as "absent" — it can never wave a version through
Prepare's preconditions or reroute Finalize into re-creating (or skipping) something.

A brief red `changelog-check` run on the PR right when it opens is expected and harmless — the
`skip-changelog` label is applied moments after PR creation, and the label's own event re-runs the
check as skipped.

## Pinned Changie

Prepare runs a pinned Changie — the `version:` input on the `changie-action` step in
`release-prepare.yml` (currently `v1.26.0`), not `latest` — so an unchanged workflow always
batches the same changelog: a new upstream release cannot break a release run or change the
rendered `.changes/<version>.md` without a reviewed bump. Bump the pin deliberately on a normal
PR and eyeball the next batched `.changes/<version>.md`; that review is the reason the pin exists.
Keep the pin in the exact `vX.Y.Z` form on that single `miniscruff/changie-action` step: the
weekly check below reads exactly one such value from `release-prepare.yml` and errors out — a red
scheduled run, not a tracking issue — if it cannot (`1.26.0` without the `v`, `latest`, a tag with a
pre-release suffix such as `v1.27.0-rc.1`, or a duplicated or removed step).

Dependabot bumps the action's commit SHA but never its `with:` inputs, so the pin would otherwise
drift silently. The weekly **"Changie pin check"** workflow (`changie-pin-check.yml`, Mondays
03:17 UTC, also runnable via `workflow_dispatch`) compares the pin with upstream's latest release
(the release GitHub marks as *latest* on `miniscruff/changie` — drafts and pre-releases excluded).
It only notifies; it never edits the repository, and the bump stays a reviewed PR:

- pin behind upstream → opens a single tracking issue labelled `changie-pin` (titled
  `release-prepare: Changie pin vA is behind upstream vB`), or retitles an older open tracker to
  the current pair rather than duplicating it; any extra open trackers are closed;
- pin current (or ahead, e.g. a deliberate pin to a `vX.Y.Z` tag GitHub marks as a pre-release)
  → closes every open tracking issue; if that exact drift later recurs (for example, because the
  pin is reverted), the workflow reopens the tracker it closed;
- a human already **closed** the issue for the current (pinned, latest) pair → stays quiet for
  that exact pair (closing without bumping is a valid decision; any older open tracker is closed
  as superseded) and only speaks up again when a newer upstream release appears.

## Partial-failure recovery

Both halves of the flow are meant to be re-run, not repaired by hand, and both fail closed rather
than guess. In every finalize state an existing `v<version>` tag must point at the PR's merge
commit (a foreign tag is a hard failure), a release whose tag is missing is a hard failure (not a
no-op), and a remote lookup error is an error, not "absent".

**Prepare failed after pushing the branch** (e.g. an API error while creating the
`skip-changelog` label or opening the PR). The run deletes `release/v<version>` itself so it stays
retryable — the precondition step refuses an existing release branch, so an orphaned one would
otherwise block every re-dispatch until someone removed it. The delete is lease-protected
(`--force-with-lease`): it only succeeds while the remote branch still points at the commit this
run pushed, so a branch someone has since moved (or already deleted) is left alone and reported,
never destroyed. Deleting the branch also auto-closes any PR that `gh` created before failing.
Simply re-dispatch "Release — Prepare PR" with the same version. If the log says the branch was
**not** deleted, inspect it and delete it by hand first — Prepare refuses to start while the
branch exists.

**Two dispatches of Prepare for the same version.** Prepare runs are serialized per version
(concurrency group `release-prepare-<version>`, never cancelled): a duplicate dispatch waits for
the first to finish, then fails on the existing-branch precondition — nothing to clean up.
Dispatches for *different* versions do not queue against each other.

**Finalize failed part-way** (e.g. it tagged `v<version>` but failed before or during publishing
the GitHub Release). Re-run the failed workflow run from the Actions tab. The workflow is
idempotent: it first probes the tag and, if one exists, requires it to point at this PR's merge
commit *before* choosing a state. It then branches on what exists:

1. Release exists and its tag was verified → full no-op.
2. Tag exists (verified) but the release does not → skips tagging, creates only the release.
3. Neither exists → pushes the annotated tag, then creates the release (the normal path). This is
   the only state in which the monotonic backstop runs: the version must be greater than the
   newest existing `v*` tag.

**Finalize refuses to run.** Each of these is a hard failure — resolve the cause, then re-run:

- a *foreign* `v<version>` tag: it exists but points at a commit other than the PR's merge
  commit. It is never overwritten, built on, or skipped past;
- a release without its `v<version>` tag (a draft, or one cut by hand): it cannot have been
  produced from this merge commit, so it is not treated as "already finalized";
- a merge commit whose `VERSION` differs from the branch's version, or that lacks
  `.changes/<version>.md` (a hand-edited release branch) — the same consistency checks the PR
  guard applies pre-merge;
- a remote lookup error (`git ls-remote` / `gh release view` failing for any reason other than
  "not found").

**Two release PRs merged close together.** Finalize runs share **one global FIFO queue** across
versions — the job-level concurrency group `release-finalize` with `queue: max`, so up to 100
pending runs wait their turn and a newly queued run can never cancel a pending one. Whichever
runs second therefore sees the first's tag:

- newer-after-older → both publish, in order;
- older-after-newer → the second run fails closed at the monotonic backstop: no tag, no release.
  (The older `VERSION` did land on `main`, which is exactly what the PR guard plus the
  up-to-date-branch requirement below are there to prevent.) Recover by cutting a corrective
  release with a higher version, or, if the out-of-order merge was intentional, tag and release
  by hand as the run's error message says.

**Need a late changie fragment after the PR is already open.** The prepare run already batched
`.changes/unreleased/` into `.changes/<version>.md` — a fragment simply committed to the release
branch stays in `unreleased/`, is **omitted from the release notes**, and merges back to `main`
(where it would ship in the *next* release instead). To include it in *this* release, either:

- close the PR, delete the `release/v*` branch, land the fragment on `main`, and re-dispatch
  "Release — Prepare PR" with the same version (cleanest — the whole batch re-runs), or
- on the release branch, fold the entry into `.changes/<version>.md` by hand (add the bullet under
  the right kind heading) and rebuild `CHANGELOG.md` with `changie merge` — never leave the new
  fragment in `.changes/unreleased/`.

## Rollback

**Yanking a bad GitHub Release.** Delete the GitHub Release from the Releases page, and delete the
`v<version>` tag if it should not stand. If you delete the tag, delete the release too: a release
left without its tag is one of the hard-failure states above, so a later re-run of finalize for
that version would refuse to proceed until it is cleaned up.

**This does not unpublish container images.** Repository releases are just a changelog marker —
they do not gate what `build.yml` has already pushed to GHCR. Image rollback is a separate,
git-revert-driven flow (see [`../CONTRIBUTING.md`](../CONTRIBUTING.md) → *Tags* / rollback). To
correct the repository changelog after a bad release, revert the release PR's commit on `main` and
cut a new *higher* version.

## Repo-settings prerequisites (one-time)

Required before the flow above works end-to-end:

- The `nq-rdl-release-bot` GitHub App is installed on this repo with `contents: write`,
  `pull requests: write`, and `issues: write` (the last is needed to apply the `skip-changelog`
  label) permissions. The App already drives the sibling repos (`agent-skills`,
  `agent-extensions`) — install it here with the same access and set `vars.RELEASE_APP_ID` +
  `secrets.RELEASE_APP_PRIVATE_KEY`.
- Because the new flow never pushes to `main` (all release content lands via the merged PR), the
  App needs **no** branch-protection bypass. If the old tag-driven flow's direct-push bypass was
  ever added, remove it — it is no longer needed.
- The **"Release — PR guard" / `version-monotonic`** check is marked as a required status check on
  `main`, and **"require branches to be up to date before merging"** is enabled. Base-branch moves
  alone do not re-run PR checks, so without the up-to-date requirement a stale release PR keeps the
  green guard run it earned before a newer version merged. (The guard job is skipped on
  non-release PRs and on fork PRs; GitHub treats a skipped required check as passing.) See
  [`branch-protection.md`](branch-protection.md).
- The **"Changie pin check"** needs nothing extra: it runs on the default `GITHUB_TOKEN` with the
  `issues: write` permission it declares itself, and creates its `changie-pin` label on first use.

**Bootstrap note.** `workflow_dispatch`, `pull_request: closed`, and `schedule` all execute the
workflow file as it exists on the **default branch**, not as it exists on a feature branch. This
release flow only works once the PR introducing it has been merged to `main` — the first release
cut with the new flow is the *next* version after that merge, and the pin check's first scheduled
run happens the Monday after.

## Maintenance

- **actionlint and `concurrency.queue`.** `release-finalize.yml` uses `queue: max` on its
  job-level `concurrency` block, which actionlint (v1.7.x) does not yet know and reports as
  `unexpected key "queue" for "concurrency" section`. `.github/actionlint.yaml` ignores exactly
  that message for exactly that file — both `pixi run actionlint` and the `actionlint` CI job read
  it automatically. Drop the ignore once actionlint learns the key.
- **Pinned actions vs. pinned inputs.** Every third-party action in the release workflows is
  pinned to a commit SHA with a `# vX.Y.Z` comment, and Dependabot bumps those SHAs. It never
  touches `with:` inputs, which is why the Changie *binary* pin (`version:` on the
  `changie-action` step) has its own weekly check ([above](#pinned-changie)) instead of relying on
  Dependabot.
