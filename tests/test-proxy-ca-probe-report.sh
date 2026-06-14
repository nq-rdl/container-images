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

if [ "$FAILURES" -gt 0 ]; then echo "${FAILURES} probe-report failure(s)"; exit 1; fi
echo "probe report contract OK"; exit 0
