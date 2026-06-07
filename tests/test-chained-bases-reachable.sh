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
# Tooling: crane and jq (both declared in pyproject.toml [tool.pixi.dependencies]; run locally
# via `pixi run policy-check-chained-bases-reachable`). In CI this script runs in
# .github/workflows/validate-base-pins.yml, where crane is provided by imjasonh/setup-crane and
# jq is ensured by an explicit step. Platforms are parsed from image.yaml with awk to avoid a
# yq-flavour dependency; image.yaml uses a simple top-level `platforms:` block list.
#
# Error-class-specific semantics (so the bootstrap skip cannot mask real failures):
#   * tag not published yet (404 / MANIFEST_UNKNOWN / NAME_UNKNOWN) -> SKIP (bootstrap)
#   * tag exists but pinned digest unreachable                      -> FAIL (placeholder/stale)
#   * any other crane error (auth / rate-limit / network)           -> FAIL (fail-closed)
#   * crane or jq absent (offline dev)                              -> SKIP loudly, exit 0
#       ...unless CHAINED_BASES_STRICT is set (CI does), then       -> FAIL (no silent green)
set -euo pipefail

# Must run from the repo root: the images/*/Containerfile glob below is repo-root-relative.
# Without this guard, invoking from another directory would match nothing and exit 0 — a
# silent false pass. CI and the pixi task already invoke this from the repo root.
[ -d images ] || { echo "ERROR: run from the repo root (images/ not found from $(pwd))"; exit 1; }

FAILURES=0
SKIPS=0
PASSES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }

# Tooling presence. CHAINED_BASES_STRICT=1 (set by the CI step) turns missing tooling into a
# hard FAIL instead of a SKIP, so a broken setup-crane action or a jq-less runner cannot make
# the job green without verifying anything. Locally (unset) absence is a loud SKIP for offline
# dev. This governs *tooling* absence only — the per-image bootstrap SKIP (unpublished tag)
# stays a SKIP even under strict mode, since a not-yet-published image genuinely cannot be
# reachability-checked.
require_tool() {  # $1: tool name
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ -n "${CHAINED_BASES_STRICT:-}" ]; then
    echo "ERROR: '$1' not on PATH and CHAINED_BASES_STRICT is set — refusing to skip in CI."; exit 1
  fi
  echo "SKIP: '$1' not on PATH — chained-base reachability not verified."
  echo "      run 'pixi install' ($1 is a declared dependency) or use the CI job."
  exit 0
}
require_tool crane
require_tool jq

# Does a crane error blob indicate an absent tag/repo (vs auth/network/other)?
# GHCR returns "MANIFEST_UNKNOWN: manifest unknown" for an absent tag on an existing repo
# (verified against ghcr.io/nq-rdl); anything else (DENIED, auth, network) falls through to FAIL.
is_absent_error() {
  grep -qiE 'MANIFEST_UNKNOWN|NAME_UNKNOWN|status code 404|: 404' <<<"$1"
}

# Read a simple top-level `platforms:` block list from an image.yaml (no yq dependency).
# Only block-sequence syntax is supported (a `platforms:` line followed by `- value` items);
# inline flow-sequence (`platforms: [a, b]`) is NOT parsed. The caller fails loudly when a
# `platforms:` key is present but nothing parses, rather than silently under-checking.
read_platforms() {
  awk '
    /^platforms:[[:space:]]*(#.*)?$/ { inblk=1; next }
    inblk && /^[^[:space:]#]/  { inblk=0 }
    inblk && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/#.*$/, ""); gsub(/["[:space:]]/, "")
      if ($0 != "") print
    }
  ' "$1"
}

shopt -s nullglob
for cf in images/*/Containerfile; do
  grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf" || continue

  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//' || true)
  if [[ "$val" != *"@sha256:"* ]]; then
    fail "$cf: BASE_CONTAINER='$val' is not digest-pinned"; continue
  fi

  repo_tag="${val%@*}"             # ghcr.io/nq-rdl/<img>:<tag>
  digest="${val##*@}"              # sha256:<hex>
  repo="${repo_tag%:*}"            # ghcr.io/nq-rdl/<img>
  digest_ref="${repo}@${digest}"   # crane rejects repo:tag@digest; address by repo@digest

  dir=$(dirname "$cf"); yaml="${dir}/image.yaml"
  # A chained image must declare its platforms in a sibling image.yaml. Missing file -> FAIL
  # (matches the yq-based step in validate-base-pins.yml); silently defaulting would under-check.
  if [ ! -f "$yaml" ]; then
    fail "$cf: missing sibling image.yaml — cannot determine declared platforms"; continue
  fi
  WANT=()
  mapfile -t WANT < <(read_platforms "$yaml")
  # Fail loudly if image.yaml declares platforms we could not parse (e.g. flow-sequence syntax)
  # instead of silently defaulting to linux/amd64 and under-checking coverage.
  if [ "${#WANT[@]}" -eq 0 ] && grep -qE '^platforms:' "$yaml"; then
    fail "$cf: ${yaml} has a 'platforms:' key but none parsed (only block-sequence supported)"; continue
  fi
  # image.yaml present but with no platforms: key -> default linux/amd64 (matches the yq step's
  # `(.platforms // ["linux/amd64"])`).
  [ "${#WANT[@]}" -gt 0 ] || WANT=("linux/amd64")

  # 1) Tag existence probe (bootstrap detection). Capture stderr only:
  #    `2>&1 >/dev/null` order is intentional — point stderr at the $() capture first, THEN
  #    send stdout to /dev/null. Reversing it (`>/dev/null 2>&1`) would discard the error text.
  if ! err=$(crane manifest "$repo_tag" 2>&1 >/dev/null); then
    if is_absent_error "$err"; then
      skip "$cf: ${repo_tag} not published yet (bootstrap) — reachability deferred"; continue
    fi
    fail "$cf: querying ${repo_tag} failed: ${err}"; continue
  fi

  # 2) Pinned-digest reachability (placeholder/stale detection). Capture stdout (the manifest
  #    JSON) and stderr separately: a stray stderr line on success (e.g. a future crane warning)
  #    must not be merged into the JSON handed to jq below.
  errf=$(mktemp)
  if ! mfst=$(crane manifest "$digest_ref" 2>"$errf"); then
    fail "$cf: pinned digest ${digest} unreachable in ${repo} (placeholder/stale): $(cat "$errf")"
    rm -f "$errf"; continue
  fi
  rm -f "$errf"

  # 3) Platform coverage: must be a non-empty image index covering every WANT platform.
  # Note: platforms are compared as "os/arch"; the OCI `variant` field (e.g. arm64/v8) is not
  # included — adequate while every image.yaml declares two-part platforms (all linux/amd64).
  # This jq filter is intentionally identical to the FROM-pin step in validate-base-pins.yml;
  # keep the two in sync if the OCI index handling changes.
  if ! have=$(jq -er '
        if (.manifests | type) == "array" and (.manifests | length) > 0
        then [.manifests[].platform | "\(.os)/\(.architecture)"] | join(" ")
        else error("not a non-empty image index") end' <<<"$mfst" 2>/dev/null); then
    fail "$cf: ${digest_ref} is not a non-empty image index (crane output: ${mfst})"; continue
  fi
  miss=0
  for p in "${WANT[@]}"; do
    grep -qw "$p" <<<"$have" || { fail "$cf: ${digest_ref} missing ${p} (has: ${have})"; miss=1; }
  done
  [ "$miss" -eq 0 ] && pass "$cf: ${digest_ref} resolves and covers ${WANT[*]}"
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} chained base(s) FAILED reachability/platform check (${PASSES} passed, ${SKIPS} skipped)"
  exit 1
fi
if [ "$PASSES" -eq 0 ]; then
  echo "No chained bases verified (${SKIPS} skipped — bootstrap or tooling absent); nothing asserted"
  exit 0
fi
echo "All ${PASSES} chained base(s) reachable and platform-covered (${SKIPS} skipped)"
exit 0
