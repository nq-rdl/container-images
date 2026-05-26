#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-hint}"

base=$(git merge-base HEAD origin/main 2>/dev/null || echo "")

if [ -z "$base" ]; then
  echo "cannot resolve merge-base with origin/main; skipping changie check"
  exit 0
fi

if git diff --name-only --diff-filter=A "$base"...HEAD -- '.changes/unreleased/*.yaml' 2>/dev/null | grep -q .; then
  exit 0
fi

if [ "$MODE" = "enforce" ]; then
  echo "error: no changie fragment added on this branch."
  echo "  run: changie new"
  echo "  or add the 'skip-changelog' label to the PR if no changelog entry is needed."
  exit 1
else
  echo ""
  echo "hint: no changie fragment added on this branch yet."
  echo "hint: run 'changie new' before pushing, or add 'skip-changelog' label to the PR."
  exit 0
fi
