#!/usr/bin/env bash
# Asserts every `ARG BASE_CONTAINER=` default in images/*/Containerfile is a digest-pinned
# repo-internal base: ghcr.io/nq-rdl/<name>:<tag>@sha256:<64-hex>.
# This restores the digest-pin guarantee that test-base-images-pinned.sh drops for the
# `FROM ${BASE_CONTAINER}` stage-ref form used by chained images.
set -euo pipefail

# Must run from the repo root: the images/*/Containerfile glob below is repo-root-relative.
# Without this guard, invoking from another directory would match nothing and exit 0 — a
# silent false pass.
[ -d images ] || { echo "ERROR: run from the repo root (images/ not found from $(pwd))"; exit 1; }

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

re='^ghcr\.io/nq-rdl/[a-z0-9._-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'

shopt -s nullglob
for cf in images/*/Containerfile; do
  # Only Containerfiles that actually chain (declare ARG BASE_CONTAINER) are in scope.
  grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf" || continue
  # Extract the default value of the LAST `ARG BASE_CONTAINER=...` line.
  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//' || true)
  if [ -z "$val" ]; then
    fail "$cf: ARG BASE_CONTAINER has no digest-pinned default"
  elif [[ "$val" =~ $re ]]; then
    pass "$cf: BASE_CONTAINER=$val"
  else
    fail "$cf: BASE_CONTAINER default '$val' is not ghcr.io/nq-rdl/<img>:<tag>@sha256:<digest>"
  fi
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} chained base(s) not properly pinned"; exit 1
else
  echo "All chained bases are digest-pinned (or none present)"; exit 0
fi
