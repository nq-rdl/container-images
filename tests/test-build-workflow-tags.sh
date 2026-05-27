#!/usr/bin/env bash
# Validates that the build workflow's metadata-action tags
# comply with CONTRIBUTING.md tag conventions.
set -euo pipefail

WORKFLOW="${1:-.github/workflows/build.yml}"

if [ ! -r "$WORKFLOW" ]; then
  echo "ERROR: workflow file not found or not readable: $WORKFLOW"
  exit 1
fi

FAILURES=0

fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

# Test: no type=sha tags (SHA tags are not in CONTRIBUTING.md)
if grep -qE 'type=sha' "$WORKFLOW"; then
  fail "build workflow contains type=sha tag (not in CONTRIBUTING.md tag scheme)"
else
  pass "no type=sha tags found"
fi

# Test: no type=schedule tags (date tags are not in CONTRIBUTING.md)
if grep -qE 'type=schedule' "$WORKFLOW"; then
  fail "build workflow contains type=schedule tag (not in CONTRIBUTING.md tag scheme)"
else
  pass "no type=schedule tags found"
fi

# Test: provenance must be explicitly disabled (build-push-action fallback creates sha256-* tags)
# Asserting "false" is present (not just "true" absent) catches accidental line removal —
# build-push-action defaults to provenance=mode=max on multi-platform builds.
if grep -qE 'provenance:[[:space:]]*false' "$WORKFLOW"; then
  pass "provenance is explicitly disabled on build-push-action"
else
  fail "build-push-action missing provenance: false (default enables sha256-* digest tags via referrers fallback)"
fi

# Test: sbom must be explicitly disabled (build-push-action fallback creates sha256-* tags)
if grep -qE 'sbom:[[:space:]]*false' "$WORKFLOW"; then
  pass "sbom is explicitly disabled on build-push-action"
else
  fail "build-push-action missing sbom: false (default enables sha256-* digest tags via referrers fallback)"
fi

# Test: GitHub-native attestation must be used (not cosign, which creates sha256-* ghost tags)
if grep -q 'actions/attest-build-provenance' "$WORKFLOW"; then
  pass "uses GitHub-native build provenance attestation"
else
  fail "missing actions/attest-build-provenance (GitHub-native attestation avoids sha256-* ghost tags)"
fi

if grep -q 'actions/attest-sbom' "$WORKFLOW"; then
  pass "uses GitHub-native SBOM attestation"
else
  fail "missing actions/attest-sbom (GitHub-native attestation avoids sha256-* ghost tags)"
fi

# Test: cosign sign/attest must NOT be used (creates sha256-* ghost tags on GHCR)
if grep -qE 'cosign sign|cosign attest' "$WORKFLOW"; then
  fail "workflow still uses cosign sign/attest (creates sha256-* ghost tags on GHCR)"
else
  pass "no cosign sign/attest commands (ghost-tag-free)"
fi

# Test: convenience alias step uses imagetools create with digest source
if ! grep -q 'imagetools create' "$WORKFLOW"; then
  fail "convenience alias step (docker buildx imagetools create) not found in workflow"
else
  pass "convenience alias step uses docker buildx imagetools create"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
else
  echo "All tests passed"
fi
