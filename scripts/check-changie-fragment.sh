#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-hint}"

if [ "${SKIP_CHANGELOG:-0}" = "1" ]; then
  echo "SKIP_CHANGELOG=1 — changie fragment check skipped"
  exit 0
fi

default_branch="main"
remote_ref="origin/${default_branch}"

base=$(git merge-base HEAD "$remote_ref" 2>/dev/null || echo "")

if [ -z "$base" ]; then
  if [ "$MODE" = "enforce" ]; then
    echo "error: cannot resolve merge-base with ${remote_ref}; refusing to skip enforcement."
    echo "  ensure 'origin' is fetched (git fetch origin ${default_branch})."
    exit 1
  fi
  echo "warning: cannot resolve merge-base with ${remote_ref}; skipping changie check"
  exit 0
fi

if git diff --name-only --diff-filter=A "$base"...HEAD -- '.changes/unreleased/*.yaml' 2>/dev/null | grep -q .; then
  exit 0
fi

if [ "$MODE" = "enforce" ]; then
  echo "error: no changie fragment added on this branch."
  echo "  run: changie new"
  echo "  to bypass: SKIP_CHANGELOG=1 git push"
  exit 1
else
  echo ""
  echo "hint: no changie fragment added on this branch yet."
  echo "hint: run 'changie new' before pushing."
  exit 0
fi
