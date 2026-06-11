#!/usr/bin/env bash
# Offline, hermetic test suite for scripts/repin-chained-base.sh.
#
# Design mirrors tests/test-chained-bases-reachable.sh: each case runs the REAL script from a
# temporary sandbox with a stub `crane` executable on PATH whose behaviour is controlled by a
# per-case environment variable (CRANE_MODE). A fake repo layout with realistic Containerfile
# fixtures (ARG BASE_CONTAINER + BOOTSTRAP PLACEHOLDER comment blocks copied from the actual jamovi
# files) is created in the sandbox so the script sees a plausible images/ tree without any network
# activity.
#
# TDD: these cases MUST fail against the original script and pass after the fixes:
#   (b) crane DENIED error  — original classifies as bootstrap skip instead of auth failure
#   (c) new digest          — original does not update the BOOTSTRAP PLACEHOLDER comment
#   (e) empty stdout        — original does not guard; rewrites a broken ARG line
#   (f) garbage stdout      — original does not guard; rewrites a broken ARG line
#   (g) path normalisation  — original appends /Containerfile twice, silently skipping the image
#   (i) network error       — original classifies as bootstrap skip and exits 0
#
# Cases that should already pass in the original (kept for regression):
#   (a) MANIFEST_UNKNOWN    — bootstrap SKIP, exit 0
#   (d) already-pinned      — OK, file byte-identical
#   (h) no @sha256: in val  — SKIP, exit 0
#
# Cases that exercise behavior introduced by the fixed script (meaningless pre-fix):
#   (j) bespoke comment     — digest repinned, non-matching comment preserved, NOTE emitted
#   (k) byte-0 comment      — comment rewrite injects no leading blank line at file start
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/repin-chained-base.sh"
[ -f "$SCRIPT" ] || { echo "ERROR: script not found: $SCRIPT"; exit 1; }

# ---------------------------------------------------------------------------
# Shared sandbox setup
# ---------------------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Realistic ARG BASE_CONTAINER default lines from the actual jamovi Containerfiles (used verbatim
# so the extraction regexes in the script are exercised on real-looking input).
PLACEHOLDER_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"
REAL_OLD_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEW_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# The BOOTSTRAP PLACEHOLDER comment block as it appears in images/jamovi-deps-ubi9/Containerfile
# and images/jamovi-ubi9/Containerfile. The script (after F6) must replace this wording when it
# performs a successful repin. We embed a realistic multi-line block so we can assert the exact
# transformation.
# shellcheck disable=SC2016  # the '"'"'s below is a literal apostrophe inside a single-quoted multi-line string;
# the apostrophe is shell-escaped (close-'  open-"  apostrophe  close-"  open-'), not a variable.
PLACEHOLDER_COMMENT_BLOCK='# ARG BASE_CONTAINER default: a BOOTSTRAP PLACEHOLDER digest. r-base-ubi9 is not published yet,
# so its tag is unresolvable and tests/test-chained-bases-reachable.sh bootstrap-SKIPs this pin
# (authenticated GHCR returns MANIFEST_UNKNOWN). A follow-up repin PR replaces the placeholder
# with the real digest after the chain'"'"'s first publish. In a bake build the docker-bake.hcl
# `contexts` + `args` wiring overrides this with the in-graph r-base target, so the digest below
# is never resolved from the registry.'

# ---------------------------------------------------------------------------
# Helper: create a minimal fake images/<x>/Containerfile
# $1 = image dir name under sandbox/images/
# $2 = ARG BASE_CONTAINER value  (full: "repo:tag@sha256:hex" or placeholder form)
# $3 = include BOOTSTRAP PLACEHOLDER comment? ("yes" or "no")
# ---------------------------------------------------------------------------
make_cf() {
  local img_name="$1" base_val="$2" with_comment="${3:-yes}"
  local dir="$SANDBOX/images/$img_name"
  mkdir -p "$dir"
  {
    printf '# syntax=docker/dockerfile:1.7\n'
    printf '#\n'
    printf '# Test chained image.\n'
    if [ "$with_comment" = "yes" ]; then
      printf '%s\n' "$PLACEHOLDER_COMMENT_BLOCK"
    fi
    printf 'ARG BASE_CONTAINER=%s\n' "$base_val"
    printf '# hadolint ignore=DL3026\n'
    # shellcheck disable=SC2016  # literal ${BASE_CONTAINER} is intentional — it is Containerfile syntax
    printf 'FROM ${BASE_CONTAINER}\n'
    printf 'LABEL org.opencontainers.image.title="%s"\n' "$img_name"
  } > "$dir/Containerfile"
}

# ---------------------------------------------------------------------------
# Stub crane: behaviour selected by CRANE_MODE env var.
#   absent        -> exit 1; prints "MANIFEST_UNKNOWN: manifest unknown" on stderr
#   denied        -> exit 1; prints "DENIED: denied" on stderr
#   network_error -> exit 1; prints "read tcp: connection refused" on stderr
#   new_digest    -> exit 0; prints NEW_DIGEST on stdout
#   old_digest    -> exit 0; prints REAL_OLD_DIGEST on stdout
#   empty         -> exit 0; prints nothing on stdout
#   garbage       -> exit 0; prints "notahex" on stdout
# ---------------------------------------------------------------------------
STUB_CRANE="$SANDBOX/bin/crane"
mkdir -p "$SANDBOX/bin"
cat > "$STUB_CRANE" <<'STUB'
#!/usr/bin/env bash
# Stub crane controlled by CRANE_MODE env var.
case "${CRANE_MODE:-}" in
  absent)
    echo "MANIFEST_UNKNOWN: manifest unknown" >&2
    exit 1 ;;
  denied)
    echo "DENIED: denied" >&2
    exit 1 ;;
  network_error)
    echo "read tcp 127.0.0.1:41234->ghcr.io:443: connection refused" >&2
    exit 1 ;;
  new_digest)
    echo "${NEW_DIGEST:?NEW_DIGEST not set}"
    exit 0 ;;
  old_digest)
    echo "${REAL_OLD_DIGEST:?REAL_OLD_DIGEST not set}"
    exit 0 ;;
  empty)
    exit 0 ;;
  garbage)
    echo "notahex"
    exit 0 ;;
  *)
    echo "stub crane: unknown CRANE_MODE='${CRANE_MODE:-}'" >&2
    exit 1 ;;
esac
STUB
chmod +x "$STUB_CRANE"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
RED_CASES=()   # cases that were red against the original script (TDD artifact — informational)

pass_case() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail_case() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# run_script_rc: invoke the real script from inside SANDBOX with stub crane on PATH.
# Captures combined stdout+stderr in $OUTPUT and exit code in $SCRIPT_EXIT.
run_script_rc() {
  local rc=0
  OUTPUT=$(
    cd "$SANDBOX"
    PATH="$SANDBOX/bin:$PATH" \
    NEW_DIGEST="$NEW_DIGEST" \
    REAL_OLD_DIGEST="$REAL_OLD_DIGEST" \
      bash "$SCRIPT" "$@" 2>&1
  ) || rc=$?
  SCRIPT_EXIT=$rc
}

# reset_sandbox_images: wipe images/ in the sandbox so each test gets a clean slate.
reset_images() {
  rm -rf "$SANDBOX/images"
  mkdir -p "$SANDBOX/images"
}

# file_content <image_name>: print the Containerfile for assertions.
file_content() { cat "$SANDBOX/images/$1/Containerfile"; }

# ---------------------------------------------------------------------------
# CASE (a): crane returns MANIFEST_UNKNOWN (absent tag) -> bootstrap SKIP, exit 0, file unchanged.
# This is the primary bootstrap path. The script must treat MANIFEST_UNKNOWN the same way
# tests/test-chained-bases-reachable.sh does: SKIP, not FAIL.
# ---------------------------------------------------------------------------
echo ""
echo "=== (a) MANIFEST_UNKNOWN -> bootstrap SKIP, exit 0 ==="
reset_images
make_cf "test-img-a" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
ORIGINAL_CONTENT=$(file_content "test-img-a")
CRANE_MODE=absent run_script_rc "images/test-img-a"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  # File must be byte-identical (no rewrite on bootstrap skip).
  CURRENT_CONTENT=$(file_content "test-img-a")
  if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
    pass_case "(a) bootstrap SKIP on MANIFEST_UNKNOWN: exit 0, file unchanged"
  else
    fail_case "(a) bootstrap SKIP on MANIFEST_UNKNOWN: file was modified despite bootstrap skip"
  fi
  # Output must say SKIP (not FAIL).
  if echo "$OUTPUT" | grep -qi "SKIP"; then
    pass_case "(a) output contains SKIP keyword"
  else
    fail_case "(a) output does not contain SKIP keyword (got: $OUTPUT)"
  fi
else
  fail_case "(a) bootstrap SKIP on MANIFEST_UNKNOWN: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (b): crane returns DENIED -> non-zero exit, file untouched, output names auth/permission.
# DENIED is NOT a bootstrap condition. The script must fail-closed (non-zero exit) and output
# must NOT call it a bootstrap skip; it must identify the error class (auth, DENIED, permission).
# ---------------------------------------------------------------------------
echo ""
echo "=== (b) DENIED error -> non-zero exit, file untouched, error class named ==="
reset_images
make_cf "test-img-b" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
ORIGINAL_CONTENT=$(file_content "test-img-b")
CRANE_MODE=denied run_script_rc "images/test-img-b"
if [ "$SCRIPT_EXIT" -ne 0 ]; then
  pass_case "(b) DENIED: non-zero exit ($SCRIPT_EXIT)"
else
  fail_case "(b) DENIED: expected non-zero exit, got exit 0 (output: $OUTPUT)"
  RED_CASES+=("(b) DENIED -> exit 0 instead of non-zero")
fi
CURRENT_CONTENT=$(file_content "test-img-b")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(b) DENIED: file untouched"
else
  fail_case "(b) DENIED: file was modified despite auth error"
fi
# Output must NOT claim this was a bootstrap condition (e.g. "not published yet (bootstrap)").
# The word "non-bootstrap" in the FATAL summary line is fine — it explicitly says it is NOT
# a bootstrap error. We match for "bootstrap)" or "bootstrap-SKIP" to avoid false positives
# on the "non-bootstrap" summary text.
if echo "$OUTPUT" | grep -qiE 'bootstrap\)|bootstrap-SKIP|not published yet'; then
  fail_case "(b) DENIED: output incorrectly claims bootstrap skip (got: $OUTPUT)"
else
  pass_case "(b) DENIED: output does not claim bootstrap skip"
fi
# Output must name the error class (DENIED, auth, or permission).
if echo "$OUTPUT" | grep -qiE "DENIED|auth|permission|error"; then
  pass_case "(b) DENIED: output names the error class"
else
  fail_case "(b) DENIED: output does not identify the error class (got: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (c): crane returns new digest -> file rewritten: digest replaced AND placeholder comment
# updated. Exit 0. This verifies both the digest swap (F1 already worked) and the comment update
# (F6 — the new requirement).
# ---------------------------------------------------------------------------
echo ""
echo "=== (c) New digest -> digest replaced + placeholder comment updated, exit 0 ==="
reset_images
make_cf "test-img-c" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
CRANE_MODE=new_digest run_script_rc "images/test-img-c"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  pass_case "(c) new digest: exit 0"
else
  fail_case "(c) new digest: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
fi
# The new digest must appear in the ARG BASE_CONTAINER line.
if grep -qF "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${NEW_DIGEST}" "$SANDBOX/images/test-img-c/Containerfile"; then
  pass_case "(c) new digest: digest replaced in ARG BASE_CONTAINER line"
else
  fail_case "(c) new digest: new digest NOT found in Containerfile (content: $(file_content test-img-c))"
  RED_CASES+=("(c) digest swap did not produce correct ARG line")
fi
# The placeholder digest must be gone.
if grep -qF "$PLACEHOLDER_DIGEST" "$SANDBOX/images/test-img-c/Containerfile"; then
  fail_case "(c) new digest: placeholder digest still present in file"
else
  pass_case "(c) new digest: placeholder digest removed"
fi
# BOOTSTRAP PLACEHOLDER wording must be gone (replaced by pinned-digest note).
if grep -qi "BOOTSTRAP PLACEHOLDER" "$SANDBOX/images/test-img-c/Containerfile"; then
  fail_case "(c) new digest: BOOTSTRAP PLACEHOLDER comment still present after repin"
  RED_CASES+=("(c) BOOTSTRAP PLACEHOLDER comment not updated (F6 not applied)")
else
  pass_case "(c) new digest: BOOTSTRAP PLACEHOLDER wording removed from comment"
fi
# The replacement comment must mention pinned/published.
if grep -qi "pinned" "$SANDBOX/images/test-img-c/Containerfile"; then
  pass_case "(c) new digest: replacement comment mentions 'pinned'"
else
  fail_case "(c) new digest: replacement comment does not mention 'pinned' (content: $(file_content test-img-c))"
fi
# Output must say REPIN.
if echo "$OUTPUT" | grep -qi "REPIN"; then
  pass_case "(c) new digest: output contains REPIN keyword"
else
  fail_case "(c) new digest: output does not contain REPIN (got: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (d): crane returns the already-pinned digest -> 'OK', file byte-identical, exit 0.
# This exercises the idempotent path — running the script a second time after a successful repin
# must be a no-op.
# ---------------------------------------------------------------------------
echo ""
echo "=== (d) Already-pinned digest -> OK, file unchanged, exit 0 ==="
reset_images
make_cf "test-img-d" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${REAL_OLD_DIGEST}" "no"
ORIGINAL_CONTENT=$(file_content "test-img-d")
CRANE_MODE=old_digest run_script_rc "images/test-img-d"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  pass_case "(d) already-pinned: exit 0"
else
  fail_case "(d) already-pinned: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
fi
CURRENT_CONTENT=$(file_content "test-img-d")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(d) already-pinned: file byte-identical"
else
  fail_case "(d) already-pinned: file was modified despite already matching (output: $OUTPUT)"
fi
if echo "$OUTPUT" | grep -qi "OK"; then
  pass_case "(d) already-pinned: output contains OK keyword"
else
  fail_case "(d) already-pinned: output does not contain OK (got: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (e): crane exit 0 with empty stdout -> non-zero exit, file untouched.
# An empty $new_digest would produce a malformed ARG line; must validate before rewrite.
# ---------------------------------------------------------------------------
echo ""
echo "=== (e) crane exit 0 with empty stdout -> non-zero exit, file untouched ==="
reset_images
make_cf "test-img-e" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
ORIGINAL_CONTENT=$(file_content "test-img-e")
CRANE_MODE=empty run_script_rc "images/test-img-e"
if [ "$SCRIPT_EXIT" -ne 0 ]; then
  pass_case "(e) empty stdout: non-zero exit ($SCRIPT_EXIT)"
else
  fail_case "(e) empty stdout: expected non-zero exit, got exit 0 (output: $OUTPUT)"
  RED_CASES+=("(e) empty crane stdout -> exit 0 instead of non-zero")
fi
CURRENT_CONTENT=$(file_content "test-img-e")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(e) empty stdout: file untouched"
else
  fail_case "(e) empty stdout: file was modified despite empty crane output"
  RED_CASES+=("(e) file rewritten with empty digest")
fi

# ---------------------------------------------------------------------------
# CASE (f): crane exit 0 with garbage stdout (not sha256:hex64) -> non-zero exit, file untouched.
# Validates the ^sha256:[0-9a-f]{64}$ guard.
# ---------------------------------------------------------------------------
echo ""
echo "=== (f) crane returns garbage -> non-zero exit, file untouched ==="
reset_images
make_cf "test-img-f" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
ORIGINAL_CONTENT=$(file_content "test-img-f")
CRANE_MODE=garbage run_script_rc "images/test-img-f"
if [ "$SCRIPT_EXIT" -ne 0 ]; then
  pass_case "(f) garbage digest: non-zero exit ($SCRIPT_EXIT)"
else
  fail_case "(f) garbage digest: expected non-zero exit, got exit 0 (output: $OUTPUT)"
  RED_CASES+=("(f) garbage crane stdout -> exit 0 instead of non-zero")
fi
CURRENT_CONTENT=$(file_content "test-img-f")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(f) garbage digest: file untouched"
else
  fail_case "(f) garbage digest: file was modified despite invalid digest format"
  RED_CASES+=("(f) file rewritten with garbage digest")
fi

# ---------------------------------------------------------------------------
# CASE (g): passing 'images/x/Containerfile' is identical to passing 'images/x'.
# The original script appends /Containerfile to any argument unconditionally, so
# images/x/Containerfile becomes images/x/Containerfile/Containerfile — a non-existent path
# that is silently SKIP'd. After F4 the script normalises both forms.
# ---------------------------------------------------------------------------
echo ""
echo "=== (g) 'images/x/Containerfile' path == 'images/x' path ==="
reset_images
make_cf "test-img-g" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
# Run with the full /Containerfile path — must repin (new_digest) identically to the dir form.
CRANE_MODE=new_digest run_script_rc "images/test-img-g/Containerfile"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  pass_case "(g) path normalisation: exit 0"
else
  fail_case "(g) path normalisation: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
  RED_CASES+=("(g) images/x/Containerfile path -> SKIP'd (double /Containerfile append)")
fi
if grep -qF "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${NEW_DIGEST}" "$SANDBOX/images/test-img-g/Containerfile"; then
  pass_case "(g) path normalisation: new digest written when full path given"
else
  fail_case "(g) path normalisation: new digest NOT written for full /Containerfile path (output: $OUTPUT)"
  RED_CASES+=("(g) new digest not written when images/x/Containerfile given")
fi

# ---------------------------------------------------------------------------
# CASE (h): Containerfile whose BASE_CONTAINER has no @sha256: -> SKIP, exit 0.
# The BASE_CONTAINER line is a valid ARG but lacks the @sha256: digest pin. This can happen if a
# Containerfile uses a tag-only reference. The script must skip it with a note, not fail.
# ---------------------------------------------------------------------------
echo ""
echo "=== (h) BASE_CONTAINER without @sha256: -> SKIP, exit 0 ==="
reset_images
make_cf "test-img-h" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0" "no"
ORIGINAL_CONTENT=$(file_content "test-img-h")
CRANE_MODE=absent run_script_rc "images/test-img-h"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  pass_case "(h) no @sha256:: exit 0"
else
  fail_case "(h) no @sha256:: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
fi
CURRENT_CONTENT=$(file_content "test-img-h")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(h) no @sha256:: file untouched"
else
  fail_case "(h) no @sha256:: file was modified (output: $OUTPUT)"
fi
if echo "$OUTPUT" | grep -qi "SKIP"; then
  pass_case "(h) no @sha256:: output contains SKIP"
else
  fail_case "(h) no @sha256:: output does not contain SKIP (got: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (i): network error (not MANIFEST_UNKNOWN, not DENIED) -> non-zero exit, file untouched.
# Any other crane error class must also fail-closed.
# ---------------------------------------------------------------------------
echo ""
echo "=== (i) network error -> non-zero exit, file untouched ==="
reset_images
make_cf "test-img-i" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "yes"
ORIGINAL_CONTENT=$(file_content "test-img-i")
CRANE_MODE=network_error run_script_rc "images/test-img-i"
if [ "$SCRIPT_EXIT" -ne 0 ]; then
  pass_case "(i) network error: non-zero exit ($SCRIPT_EXIT)"
else
  fail_case "(i) network error: expected non-zero exit, got exit 0 (output: $OUTPUT)"
  RED_CASES+=("(i) network error -> exit 0 instead of non-zero")
fi
CURRENT_CONTENT=$(file_content "test-img-i")
if [ "$CURRENT_CONTENT" = "$ORIGINAL_CONTENT" ]; then
  pass_case "(i) network error: file untouched"
else
  fail_case "(i) network error: file was modified despite network error"
fi

# ---------------------------------------------------------------------------
# CASE (j): comment idempotence — a Containerfile whose comment block does NOT match the
# BOOTSTRAP PLACEHOLDER wording (already repinned, or bespoke comment) is left untouched.
# The digest is still updated; only the unknown comment block is left alone.
# Also verify the NOTE output flags the unmatched comment so the operator knows it was not
# auto-updated.
# ---------------------------------------------------------------------------
echo ""
echo "=== (j) comment idempotence — non-matching comment block left alone ==="
reset_images
# Use 'no' for the placeholder comment; put a bespoke comment instead.
make_cf "test-img-j" "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}" "no"
# Insert a bespoke (non-matching) comment before the ARG line.
BESPOKE_COMMENT="# ARG BASE_CONTAINER default: a custom note that does not match the template."
sed -i "s|ARG BASE_CONTAINER=|${BESPOKE_COMMENT}\nARG BASE_CONTAINER=|" \
  "$SANDBOX/images/test-img-j/Containerfile"
CRANE_MODE=new_digest run_script_rc "images/test-img-j"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  pass_case "(j) bespoke comment: exit 0"
else
  fail_case "(j) bespoke comment: expected exit 0, got exit $SCRIPT_EXIT (output: $OUTPUT)"
fi
# Digest must be updated.
if grep -qF "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${NEW_DIGEST}" "$SANDBOX/images/test-img-j/Containerfile"; then
  pass_case "(j) bespoke comment: digest updated despite non-matching comment"
else
  fail_case "(j) bespoke comment: digest NOT updated (output: $OUTPUT)"
fi
# The bespoke comment must remain intact (not removed or replaced).
if grep -qF "$BESPOKE_COMMENT" "$SANDBOX/images/test-img-j/Containerfile"; then
  pass_case "(j) bespoke comment: non-matching comment preserved"
else
  fail_case "(j) bespoke comment: non-matching comment was modified or removed"
fi
# The script must surface the unmatched comment via its NOTE output, so the operator knows the
# comment was not auto-updated and may need a manual touch-up.
if grep -qF "NOTE: BOOTSTRAP PLACEHOLDER comment not found or already updated" <<<"$OUTPUT"; then
  pass_case "(j) bespoke comment: NOTE about unmatched comment emitted"
else
  fail_case "(j) bespoke comment: missing NOTE about unmatched comment (output: $OUTPUT)"
fi

# ---------------------------------------------------------------------------
# CASE (k): placeholder block at byte 0 of the file — the comment rewrite must not inject a
# spurious leading blank line. make_cf always emits header lines first (as the real jamovi
# Containerfiles do), so this fixture is built manually with the placeholder block as the very
# first line.
# ---------------------------------------------------------------------------
echo ""
echo "=== (k) placeholder block at byte 0 — no leading blank line injected on repin ==="
reset_images
mkdir -p "$SANDBOX/images/test-img-k"
{
  printf '%s\n' "$PLACEHOLDER_COMMENT_BLOCK"
  printf 'ARG BASE_CONTAINER=%s\n' "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${PLACEHOLDER_DIGEST}"
  # shellcheck disable=SC2016  # literal ${BASE_CONTAINER} is intentional — Containerfile syntax
  printf 'FROM ${BASE_CONTAINER}\n'
} > "$SANDBOX/images/test-img-k/Containerfile"
CRANE_MODE=new_digest run_script_rc "images/test-img-k"
if grep -qF "ghcr.io/nq-rdl/r-base-ubi9:4.5.0@${NEW_DIGEST}" "$SANDBOX/images/test-img-k/Containerfile"; then
  pass_case "(k) byte-0 comment block: digest updated"
else
  fail_case "(k) byte-0 comment block: digest NOT updated (output: $OUTPUT)"
fi
first_char=$(head -c 1 "$SANDBOX/images/test-img-k/Containerfile")
if [ "$first_char" = "#" ]; then
  pass_case "(k) byte-0 comment block: file still starts with the comment (no blank line)"
else
  fail_case "(k) byte-0 comment block: leading blank line injected (first line: '$(head -1 "$SANDBOX/images/test-img-k/Containerfile")')"
  RED_CASES+=("(k) byte-0 comment block -> spurious leading blank line")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [ "${#RED_CASES[@]}" -gt 0 ]; then
  echo ""
  echo "TDD red cases (expected failures against original script):"
  for c in "${RED_CASES[@]}"; do echo "  - $c"; done
fi
echo "=================================================================="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
