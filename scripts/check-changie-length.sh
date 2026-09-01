#!/usr/bin/env bash
# Lint the changie fragments ADDED on this branch against the per-fragment body
# cap (default 200 chars). The cap itself lives in .changie.yaml
# (body.maxLength) and only guards `changie new`; this wrapper catches fragments
# written directly (hand-authored, agent-edited, copy-pasted) by re-reading them
# with scripts/check_changie_length.py. CHANGIE_MAX_BODY_LENGTH is read by the
# Python checker, so exporting it here overrides the cap without any plumbing.
#
# Scope mirrors CI (.github/workflows/changelog-check.yml), which lints only
# `--diff-filter=A` fragments: the union of
#   * fragments added between the merge-base with origin/main (CHANGIE_BASE_REF
#     overrides, e.g. upstream/main on a fork whose origin/main is stale) and
#     HEAD, and
#   * fragments staged as added but not yet committed (so the pre-commit hook
#     sees the fragment in the commit being made), and
#   * untracked fragments (a fresh `changie new` not yet `git add`ed), so
#     `pixi run lint-changie` never gives a false all-clear.
# Pre-existing unreleased fragments are never retroactively flagged — several
# predate the cap and exceed it. If the merge-base cannot be resolved (origin
# not fetched), only the staged-added set is linted; there is deliberately no
# fallback to scanning every unreleased fragment.
#
# On failure the checker prints one ::error:: per offending fragment plus the
# split-into-multiple-fragments reminder: a change too long for one fragment
# becomes several (`changie new` again) — there is no cap on fragment count.
#
# Usage (takes no arguments):
#   scripts/check-changie-length.sh
#   pixi run lint-changie
#   CHANGIE_MAX_BODY_LENGTH=150 scripts/check-changie-length.sh
#   CHANGIE_BASE_REF=upstream/main scripts/check-changie-length.sh
#
# Wired as the 'changie fragment length' pre-commit hook (.pre-commit-config.yaml);
# bypass it for one commit with SKIP=changie-length.
# Requires python3 with pyyaml (the pixi env provides both).
set -euo pipefail

base_ref="${CHANGIE_BASE_REF:-origin/main}"
fragment_glob='.changes/unreleased/*.yaml'
checker="scripts/check_changie_length.py"

# Fragment paths must be repo-relative (.changes/unreleased/<name>.yaml) for the
# checker's scope test, so always operate from the repository root.
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

branch_added=""
base=$(git merge-base HEAD "$base_ref" 2>/dev/null || echo "")
if [ -z "$base" ]; then
  echo "warning: cannot resolve merge-base with ${base_ref}; linting staged fragments only."
  echo "  fetch it (git fetch origin main) or point CHANGIE_BASE_REF at another ref."
else
  branch_added=$(git diff --name-only --diff-filter=A "${base}...HEAD" -- "$fragment_glob")
fi
staged_added=$(git diff --cached --name-only --diff-filter=A -- "$fragment_glob")
untracked=$(git ls-files --others --exclude-standard -- "$fragment_glob")

files=()
while IFS= read -r fragment; do
  [ -n "$fragment" ] || continue
  files+=("$fragment")
done < <(printf '%s\n%s\n%s\n' "$branch_added" "$staged_added" "$untracked" | sort -u)

if [ "${#files[@]}" -eq 0 ]; then
  echo "no changie fragments added on this branch; nothing to length-lint."
  exit 0
fi

echo "length-linting ${#files[@]} changie fragment(s) added on this branch:"
printf '  %s\n' "${files[@]}"
python3 "$checker" "${files[@]}"
