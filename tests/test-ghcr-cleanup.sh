#!/usr/bin/env bash
#
# Regression tests for scripts/ghcr-cleanup.sh.
#
# These run the real cleanup script end-to-end with `gh`, `skopeo` and `docker`
# replaced by stubs, so no network or registry access is needed. They assert on
# the keep / recent / delete partition AND on the exact set of version IDs the
# script chooses to delete in --execute mode.
#
# The deletion selection is the safety-critical behaviour: a regression here
# either leaves the sha256-* / orphaned-manifest pollution in place (the bug this
# workflow exists to fix) or, far worse, deletes a live image's child manifests.
# Pin it down so future edits to the script cannot silently change it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/ghcr-cleanup.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Deterministic 64-char hex fragments from a small integer (digits are valid hex).
hex64()        { printf '%064d' "$1"; }
digest()       { printf 'sha256:%s' "$(hex64 "$1")"; }
referrer_tag() { printf 'sha256-%s' "$(hex64 "$1")"; }

TS_OLD="2020-01-01T00:00:00Z"          # well outside any grace window
ts_recent() { date -u +%Y-%m-%dT%H:%M:%SZ; }   # inside the grace window

WORK=""

setup_env() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/versions" "$WORK/manifests"
  export GHCR_TEST_VERSIONS="$WORK/versions"
  export GHCR_TEST_MANIFESTS="$WORK/manifests"
  export GHCR_TEST_DELETED="$WORK/deleted.log"
  : > "$GHCR_TEST_DELETED"

  # Stub `gh`: serve a package's version list from a fixture TSV, and record the
  # version IDs that --execute asks to DELETE (always reporting success).
  cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
all="$*"
path=""
for a in "$@"; do
  case "$a" in /orgs/*) path="$a" ;; esac
done
if [[ "$all" == *"--method DELETE"* ]]; then
  printf '%s\n' "${path##*/versions/}" >> "$GHCR_TEST_DELETED"
  exit 0
fi
rest="${path#*/container/}"
pkg="${rest%%/versions*}"
f="$GHCR_TEST_VERSIONS/$pkg.tsv"
if [[ -f "$f" ]]; then cat "$f"; exit 0; fi
echo "gh: HTTP 404: Not Found" >&2
exit 1
STUB

  # Stub `skopeo`: return the raw manifest fixture for the requested digest.
  cat > "$WORK/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
ref=""
for a in "$@"; do
  case "$a" in docker://*) ref="${a#docker://}" ;; esac
done
d="${ref##*@}"
f="$GHCR_TEST_MANIFESTS/${d//[^a-zA-Z0-9]/_}.json"
if [[ -f "$f" ]]; then cat "$f"; exit 0; fi
exit 1
STUB

  # Stub `docker`: must never be reached (skopeo resolves every fixture). Failing
  # loudly guarantees a missing fixture surfaces as a test failure, not a real
  # `docker buildx imagetools` call against the live registry.
  cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker stub: unexpected call: $*" >&2
exit 1
STUB

  chmod +x "$WORK/bin/gh" "$WORK/bin/skopeo" "$WORK/bin/docker"
  PATH="$WORK/bin:$PATH"
  export PATH
}

teardown_env() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  WORK=""
}

# add_version <pkg> <id> <digest> <tags> <created>
# Fields are US-separated (ASCII 0x1f), mirroring the script's `gh ... | join`
# output. An untagged version therefore has a genuinely empty tags field — the
# exact shape that broke tab-separated parsing.
add_version() {
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$2" "$3" "$4" "$5" >> "$GHCR_TEST_VERSIONS/$1.tsv"
}

# set_manifest <digest> <json>
set_manifest() {
  printf '%s' "$2" > "$GHCR_TEST_MANIFESTS/${1//[^a-zA-Z0-9]/_}.json"
}

RUN_OUT=""
RUN_RC=0
# run_script <pkg> [grace_minutes]
run_script() {
  local pkg="$1" grace="${2:-360}"
  set +e
  RUN_OUT="$(GHCR_ORG=testorg GHCR_PACKAGES="$pkg" GHCR_GRACE_MINUTES="$grace" \
              bash "$SCRIPT" --execute 2>&1)"
  RUN_RC=$?
  set -e
}

assert_contains() {  # <msg> <needle>
  if printf '%s' "$RUN_OUT" | grep -qF "$2"; then pass "$1"; else
    fail "$1 (output missing: $2)"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    | /'
  fi
}

assert_rc() {  # <msg> <expected_rc>
  if [ "$RUN_RC" -eq "$2" ]; then pass "$1"; else fail "$1 (rc=$RUN_RC, want $2)"; fi
}

assert_deleted_exactly() {  # <msg> [id...]
  local msg="$1"; shift
  local want got
  if [ "$#" -eq 0 ]; then want=""; else want="$(printf '%s\n' "$@" | sort -u)"; fi
  got="$(sort -u "$GHCR_TEST_DELETED")"
  if [ "$want" = "$got" ]; then
    pass "$msg"
  else
    fail "$msg (deleted want=[$(echo "$want" | tr '\n' ' ')] got=[$(echo "$got" | tr '\n' ' ')])"
  fi
}

# ---------------------------------------------------------------------------
# Case 1: multi-arch index — keep the index + its children, delete the old
# orphan and old referrer tag, protect the recent orphan and the garbage
# timestamp. This is the core partition + the catastrophic "never delete a
# live child" guarantee.
# ---------------------------------------------------------------------------
setup_env
REAL=$(digest 1); C1=$(digest 2); C2=$(digest 3)
ORPHAN=$(digest 4); RECENT=$(digest 5); REF=$(digest 6); GARB=$(digest 7)
add_version testimg 101 "$REAL"   "latest,1.0"          "$TS_OLD"
add_version testimg 102 "$C1"     ""                    "$TS_OLD"
add_version testimg 103 "$C2"     ""                    "$TS_OLD"
add_version testimg 104 "$ORPHAN" ""                    "$TS_OLD"
add_version testimg 105 "$RECENT" ""                    "$(ts_recent)"
add_version testimg 106 "$REF"    "$(referrer_tag 6)"   "$TS_OLD"
add_version testimg 107 "$GARB"   ""                    "not-a-real-timestamp"
set_manifest "$REAL" "{\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"digest\":\"$C1\"},{\"digest\":\"$C2\"}]}"
run_script testimg
assert_rc       "multi-arch: script exits 0" 0
assert_contains "multi-arch: keeps real index + its 2 children (keep=3)" "keep=3"
assert_contains "multi-arch: protects recent orphan + garbage timestamp (recent=2)" "recent=2"
assert_contains "multi-arch: targets old orphan + old referrer (delete=2)" "delete=2"
assert_deleted_exactly "multi-arch: deletes EXACTLY the orphan and referrer; children untouched" 104 106
teardown_env

# ---------------------------------------------------------------------------
# Case 2: single-arch image (config+layers, no child manifests). The orphan
# must still be deletable — i.e. the hardened classifier treats a plain image
# manifest as "image" (resolve OK), not "unknown" (skip).
# ---------------------------------------------------------------------------
setup_env
RIMG=$(digest 11); SORPH=$(digest 12)
add_version single 201 "$RIMG"  "latest" "$TS_OLD"
add_version single 202 "$SORPH" ""       "$TS_OLD"
set_manifest "$RIMG" "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"digest\":\"$(digest 91)\"},\"layers\":[{\"digest\":\"$(digest 92)\"}]}"
run_script single
assert_rc       "single-arch: script exits 0" 0
assert_contains "single-arch: keeps the real image manifest (keep=1)" "keep=1"
assert_contains "single-arch: still deletes the orphan (delete=1)" "delete=1"
assert_deleted_exactly "single-arch: deletes EXACTLY the orphan" 202
teardown_env

# ---------------------------------------------------------------------------
# Case 3: fail-closed hardening. A real tag resolves to valid JSON of an
# unrecognised shape (neither index nor image). The package must be SKIPPED
# (keep all) — never silently treated as "no children" so its orphan gets
# deleted. This case FAILS against the pre-hardening `if .manifests ...` logic.
# ---------------------------------------------------------------------------
setup_env
WREAL=$(digest 21); WORPH=$(digest 22)
add_version weird 301 "$WREAL" "latest" "$TS_OLD"
add_version weird 302 "$WORPH" ""       "$TS_OLD"
set_manifest "$WREAL" "{\"schemaVersion\":2,\"unexpected\":\"shape\"}"
run_script weird
assert_rc       "fail-closed: script exits 0" 0
assert_contains "fail-closed: unrecognised manifest shape -> package skipped" "SKIP"
assert_deleted_exactly "fail-closed: nothing deleted; orphan protected"
teardown_env

# ---------------------------------------------------------------------------
# Case 4: referrer-tag precision. A real tag that merely starts with "sha256-"
# but is not sha256-<64 hex> must be treated as a real tag (kept), not as an
# attestation referrer to delete.
# ---------------------------------------------------------------------------
setup_env
PD=$(digest 31)
add_version oddtag 401 "$PD" "sha256-not-a-64-hex-digest" "$TS_OLD"
set_manifest "$PD" "{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"digest\":\"$(digest 93)\"},\"layers\":[{\"digest\":\"$(digest 94)\"}]}"
run_script oddtag
assert_rc       "referrer-precision: script exits 0" 0
assert_contains "referrer-precision: non-referrer sha256- tag kept as real (keep=1)" "keep=1"
assert_deleted_exactly "referrer-precision: nothing deleted"
teardown_env

echo "----"
if [ "$fails" -eq 0 ]; then
  echo "All ghcr-cleanup tests passed."
else
  echo "${fails} ghcr-cleanup test(s) failed."
  exit 1
fi
