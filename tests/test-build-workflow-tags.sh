#!/usr/bin/env bash
# Validates that the build workflow's metadata-action tags
# comply with CONTRIBUTING.md tag conventions.
set -euo pipefail

WORKFLOW="${1:-.github/workflows/build.yml}"
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

# Test: cosign sign must exist and use OCI 1.1 referrers
if ! grep -q 'cosign sign' "$WORKFLOW"; then
  fail "cosign sign command not found in workflow"
elif grep 'cosign sign' "$WORKFLOW" | grep -qF 'registry-referrers-mode=oci-1-1'; then
  pass "cosign sign uses --registry-referrers-mode=oci-1-1"
else
  fail "cosign sign missing --registry-referrers-mode=oci-1-1 (creates .sig tag artifacts)"
fi

# Test: cosign attest must exist and use OCI 1.1 referrers
if ! grep -q 'cosign attest' "$WORKFLOW"; then
  fail "cosign attest command not found in workflow"
elif grep -A5 'cosign attest' "$WORKFLOW" | grep -qF 'registry-referrers-mode=oci-1-1'; then
  pass "cosign attest uses --registry-referrers-mode=oci-1-1"
else
  fail "cosign attest missing --registry-referrers-mode=oci-1-1 (creates .att tag artifacts)"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
else
  echo "All tests passed"
fi
