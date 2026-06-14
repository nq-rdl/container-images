#!/usr/bin/env bash
# Hermetic test of images/proxy-ca-probe-ubi9/proxy-ca-probe.py.
# Runs the probe in --self-test mode (no network): it must emit schema-valid
# JSON, set per-check status, and exit 0 only when every non-skipped check
# passed. Self-test mode needs no network or external toolchain.
#
# A && pass || fail is intentional throughout: the pass/grep helpers never fail
# spuriously, so the SC2015 if-then-else caveat does not apply here.
# shellcheck disable=SC2015
set -euo pipefail
[ -d images ] || { echo "ERROR: run from the repo root"; exit 1; }

PROBE=images/proxy-ca-probe-ubi9/proxy-ca-probe.py
FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# (a) self-test emits valid JSON with the required top-level keys
out="$(python3 "$PROBE" --self-test --report json)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
req={"schema_version","target_url","proxy","summary","checks"}
assert req <= set(d), f"missing keys: {req - set(d)}"
assert {"total","passed","failed","skipped"} <= set(d["summary"])
for c in d["checks"]:
    assert {"id","toolchain","category","status","detail","remediation"} <= set(c)
    assert c["status"] in {"pass","fail","skip"}
' && pass "(a) self-test JSON is schema-valid" || fail "(a) self-test JSON schema"

# (b) exit code reflects failures: a forced-fail self-test exits non-zero
if PROBE_FORCE_FAIL=1 python3 "$PROBE" --self-test --report json >/dev/null; then
  fail "(b) forced-fail self-test should exit non-zero"
else
  pass "(b) forced-fail self-test exits non-zero"
fi

# (c) human report is non-empty and mentions PASS/FAIL
python3 "$PROBE" --self-test --report human | grep -qE 'PASS|FAIL' \
  && pass "(c) human report renders" || fail "(c) human report"

# (d) live-check wiring with STUBBED toolchains (hermetic, no real network).
# Stub curl/openssl/node/git/java as no-op exit-0 binaries on PATH, point the
# probe at an unroutable proxy (fast connection-refused for the un-stubbed
# python urllib check), and assert the live path wired per-toolchain checks.
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT
for tool in curl openssl node git java; do
  printf '#!/bin/sh\nexit 0\n' > "${STUBDIR}/${tool}"
  chmod +x "${STUBDIR}/${tool}"
done
# Capture JSON even though the probe exits non-zero (un-stubbed python fails).
out="$(PATH="${STUBDIR}:${PATH}" TARGET_URL=https://example.test \
  HTTPS_PROXY=http://127.0.0.1:1 python3 "$PROBE" --report json || true)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
tcs={c["toolchain"] for c in d["checks"]}
for want in ("curl","python","node"):
    assert want in tcs, f"no {want} check wired; toolchains={sorted(tcs)}"
' && pass "(d) live checks wire curl/python/node toolchains" \
  || fail "(d) live-check toolchain wiring"

# (e) a timed-out toolchain must become a 'fail' check, not crash the probe.
# Stub curl as a slow command that outlives PROBE_CMD_TIMEOUT; the others stay
# fast exit-0. The probe must still emit valid JSON (no traceback) and record
# the curl check as status=fail.
SLOWDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR" "$SLOWDIR"' EXIT
printf '#!/bin/sh\nsleep 5\n' > "${SLOWDIR}/curl"
chmod +x "${SLOWDIR}/curl"
for tool in openssl node git java; do
  printf '#!/bin/sh\nexit 0\n' > "${SLOWDIR}/${tool}"
  chmod +x "${SLOWDIR}/${tool}"
done
out="$(PATH="${SLOWDIR}:${PATH}" TARGET_URL=https://example.test \
  HTTPS_PROXY=http://127.0.0.1:1 PROBE_CMD_TIMEOUT=1 \
  python3 "$PROBE" --report json || true)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)  # raises (test fails) if the probe crashed / no JSON
curl=[c for c in d["checks"] if c["toolchain"]=="curl"]
assert curl, "no curl check emitted"
st=curl[0]["status"]
assert st=="fail", "curl status="+st
' && pass "(e) timed-out toolchain fails gracefully" \
  || fail "(e) timeout handling"

# (f) CORP_CA_FINGERPRINT is normalized the same way as bundle fingerprints
# (strip colons, lowercase) so a human-supplied fingerprint can match.
python3 - <<'PY' && pass "(f) fingerprint normalization" || fail "(f) fingerprint normalization"
import importlib.util
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m._normalize_fp("DE:FF:6F:00") == "deff6f00", m._normalize_fp("DE:FF:6F:00")
PY

if [ "$FAILURES" -gt 0 ]; then echo "${FAILURES} probe-report failure(s)"; exit 1; fi
echo "probe report contract OK"; exit 0
