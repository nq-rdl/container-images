#!/usr/bin/env bash
# Asserts every external-registry FROM in images/*/Containerfile is pinned by @sha256:.
# Stage refs (FROM <stage>), COPY --from, and FROM scratch are exempt.
set -euo pipefail

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

shopt -s nullglob
for cf in images/*/Containerfile; do
  while IFS= read -r line; do
    # Strip 'FROM', any --platform flag, and trailing 'AS <stage>'; take the image ref.
    ref=$(echo "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/--platform=[^[:space:]]+[[:space:]]+//; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//')
    img=$(echo "$ref" | awk '{print $1}')

    [ "$img" = "scratch" ] && { pass "$cf: FROM scratch (exempt)"; continue; }
    # Stage-to-stage ref: no registry/repo separator, no tag, no digest.
    if [[ "$img" != *"/"* && "$img" != *"."* && "$img" != *":"* && "$img" != *"@"* ]]; then
      pass "$cf: FROM $img (stage ref, exempt)"; continue
    fi

    # shellcheck disable=SC2016  # single-quoted '${ ' is intentionally literal
    if [[ "$img" == *"@sha256:"* && "$img" != *'${'* ]]; then
      pass "$cf: $img is digest-pinned"
    else
      fail "$cf: '$img' is NOT digest-pinned (use ':tag@sha256:...', no \${...})"
    fi
  done < <(grep -iE '^[[:space:]]*FROM[[:space:]]' "$cf")
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} unpinned base(s) found"; exit 1
else
  echo "All external base images are digest-pinned"; exit 0
fi
