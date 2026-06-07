#!/usr/bin/env bash
# Asserts every `ARG BASE_CONTAINER=` chained base in images/*/Containerfile is a LIVE
# pin: its pinned @sha256 digest resolves in GHCR AND the resolved image index covers
# the platforms declared in the sibling image.yaml.
#
# Why this exists: tests/test-chained-bases-pinned.sh validates only the digest *format*
# (a placeholder digest passes that regex). This test catches placeholder/stale digests
# that do not actually exist in the registry — the failure mode a standalone
# `docker build images/scipy-notebook-ubi9` hits as `manifest unknown`.
#
# Tooling: crane (declared in pyproject.toml [tool.pixi.dependencies]; CI installs it via
# imjasonh/setup-crane) and jq. Platforms are parsed from image.yaml with awk to avoid a
# yq-flavour dependency; image.yaml uses a simple top-level `platforms:` block list.
#
# Error-class-specific semantics (so the bootstrap skip cannot mask real failures):
#   * tag not published yet (404 / MANIFEST_UNKNOWN / NAME_UNKNOWN) -> SKIP (bootstrap)
#   * tag exists but pinned digest unreachable                      -> FAIL (placeholder/stale)
#   * any other crane error (auth / rate-limit / network)           -> FAIL (fail-closed)
#   * crane absent entirely (offline dev)                           -> SKIP loudly, exit 0
set -euo pipefail

FAILURES=0
SKIPS=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }

if ! command -v crane >/dev/null 2>&1; then
  echo "SKIP: 'crane' not on PATH — chained-base reachability not verified."
  echo "      run 'pixi install' (crane is a declared dependency) or use the CI job."
  exit 0
fi

# Does a crane error blob indicate an absent tag/repo (vs auth/network/other)?
is_absent_error() {
  grep -qiE 'MANIFEST_UNKNOWN|NAME_UNKNOWN|not found|status code 404|: 404' <<<"$1"
}

# Read a simple top-level `platforms:` block list from an image.yaml (no yq dependency).
read_platforms() {
  awk '
    /^platforms:[[:space:]]*$/ { inblk=1; next }
    inblk && /^[^[:space:]#]/  { inblk=0 }
    inblk && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["[:space:]]/, "")
      if ($0 != "") print
    }
  ' "$1"
}

shopt -s nullglob
for cf in images/*/Containerfile; do
  grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf" || continue

  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//')
  if [[ "$val" != *"@sha256:"* ]]; then
    fail "$cf: BASE_CONTAINER='$val' is not digest-pinned"; continue
  fi

  repo_tag="${val%@*}"             # ghcr.io/nq-rdl/<img>:<tag>
  digest="${val##*@}"              # sha256:<hex>
  repo="${repo_tag%:*}"            # ghcr.io/nq-rdl/<img>
  digest_ref="${repo}@${digest}"   # crane rejects repo:tag@digest; address by repo@digest

  dir=$(dirname "$cf"); yaml="${dir}/image.yaml"
  WANT=()
  [ -f "$yaml" ] && mapfile -t WANT < <(read_platforms "$yaml")
  [ "${#WANT[@]}" -gt 0 ] || WANT=("linux/amd64")

  # 1) Tag existence probe (bootstrap detection). Capture stderr only.
  if ! err=$(crane manifest "$repo_tag" 2>&1 >/dev/null); then
    if is_absent_error "$err"; then
      skip "$cf: ${repo_tag} not published yet (bootstrap) — reachability deferred"; continue
    fi
    fail "$cf: querying ${repo_tag} failed: ${err}"; continue
  fi

  # 2) Pinned-digest reachability (placeholder/stale detection).
  if ! mfst=$(crane manifest "$digest_ref" 2>&1); then
    fail "$cf: pinned digest ${digest} unreachable in ${repo} (placeholder/stale): ${mfst}"; continue
  fi

  # 3) Platform coverage: must be a non-empty image index covering every WANT platform.
  if ! have=$(jq -er '
        if (.manifests | type) == "array" and (.manifests | length) > 0
        then [.manifests[].platform | "\(.os)/\(.architecture)"] | join(" ")
        else error("not a non-empty image index") end' <<<"$mfst" 2>/dev/null); then
    fail "$cf: ${digest_ref} is not a non-empty image index"; continue
  fi
  miss=0
  for p in "${WANT[@]}"; do
    grep -qw "$p" <<<"$have" || { fail "$cf: ${digest_ref} missing ${p} (has: ${have})"; miss=1; }
  done
  [ "$miss" -eq 0 ] && pass "$cf: ${digest_ref} resolves and covers ${WANT[*]}"
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} chained base(s) FAILED reachability/platform check (${SKIPS} skipped)"
  exit 1
fi
echo "All chained bases reachable and platform-covered (${SKIPS} skipped)"
exit 0
