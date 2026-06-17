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

# (g) T3: a tool that writes output THEN times out. On TimeoutExpired the buffered
# stdout/stderr are bytes (even under text=True), so the timeout handler must decode
# them before concatenating the " timed out" message. The probe must still emit valid
# JSON (no TypeError traceback) and record the curl check as status=fail.
PARTIALDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR" "$SLOWDIR" "$PARTIALDIR"' EXIT
printf '#!/bin/sh\necho partial >&2\nsleep 5\n' > "${PARTIALDIR}/curl"
chmod +x "${PARTIALDIR}/curl"
for tool in openssl node git java; do
  printf '#!/bin/sh\nexit 0\n' > "${PARTIALDIR}/${tool}"
  chmod +x "${PARTIALDIR}/${tool}"
done
out="$(PATH="${PARTIALDIR}:${PATH}" TARGET_URL=https://example.test \
  HTTPS_PROXY=http://127.0.0.1:1 PROBE_CMD_TIMEOUT=1 \
  python3 "$PROBE" --report json || true)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)  # raises (test fails) if the probe crashed / no JSON
curl=[c for c in d["checks"] if c["toolchain"]=="curl"]
assert curl, "no curl check emitted"
st=curl[0]["status"]
assert st=="fail", "curl status="+st
' && pass "(g) partial-output timeout decodes gracefully" \
  || fail "(g) partial-output timeout handling"

# (h) T5: a TARGET_URL that yields no hostname (invalid URL / missing scheme) must
# not crash the probe (host=None would reach the openssl argv). The probe must emit
# valid JSON and record a fail check flagging the bad target URL instead of raising.
URLDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR" "$SLOWDIR" "$PARTIALDIR" "$URLDIR"' EXIT
for tool in curl openssl node git java; do
  printf '#!/bin/sh\nexit 0\n' > "${URLDIR}/${tool}"
  chmod +x "${URLDIR}/${tool}"
done
out="$(PATH="${URLDIR}:${PATH}" TARGET_URL=not-a-valid-url \
  HTTPS_PROXY=http://127.0.0.1:1 python3 "$PROBE" --report json || true)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)  # raises (test fails) if the probe crashed / no JSON
bad=[c for c in d["checks"]
     if c["status"]=="fail" and ("target" in c["id"].lower() or "url" in c["detail"].lower())]
assert bad, "no fail check flagging the bad TARGET_URL; checks="+repr(d["checks"])
' && pass "(h) invalid TARGET_URL fails gracefully" \
  || fail "(h) invalid TARGET_URL handling"

# (i) T2: openssl `-proxy_pass` is a password SOURCE, not a literal password. The
# decoded password must be passed as "pass:<decoded>" (else OpenSSL aborts with
# "Invalid password argument" on a normal user:secret@proxy URL). `-proxy` must be a
# bare host:port (no scheme/creds).
python3 - <<'PY' && pass "(i) openssl proxy_pass uses pass: source" || fail "(i) openssl proxy_pass source"
import importlib.util
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cmd = m._openssl_cmd("example.com", 443, "proxy.corp", 8080,
                     proxy_user="user", proxy_pass="secret")
assert "-proxy_pass" in cmd, cmd
i = cmd.index("-proxy_pass")
assert cmd[i+1] == "pass:secret", cmd[i+1]
j = cmd.index("-proxy")
assert cmd[j+1] == "proxy.corp:8080", cmd[j+1]
PY

# (j) T4: the curl probe is TLS/proxy-only, so it must NOT use -f/--fail (a reachable
# TARGET_URL returning 401/403/404 succeeds at TLS+proxy yet exits non-zero under
# --fail, filing a false CA/proxy bug). Keep -sS so genuine connection/TLS errors
# still surface, and target TARGET_URL.
python3 - <<'PY' && pass "(j) curl probe drops --fail" || fail "(j) curl --fail dropped"
import importlib.util
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cmd = m._curl_cmd("https://example.com")
assert "-f" not in cmd and "--fail" not in cmd, cmd
joined = " ".join(cmd)
assert "-fsS" not in joined, cmd  # the old combined flag bundled -f
assert "-sS" in cmd or ("-s" in cmd and "-S" in cmd), cmd
assert "https://example.com" in cmd, cmd
PY

# (k) T1: _bundle_fingerprints is best-effort - any read/parse failure yields an
# empty/partial set rather than raising. Characterize that a nonexistent path
# returns set() and never throws (pins the intentional swallow-and-continue).
python3 - <<'PY' && pass "(k) bundle fingerprints best-effort" || fail "(k) bundle fingerprints best-effort"
import importlib.util
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m._bundle_fingerprints("/nonexistent/path") == set()
PY

# (l) T6: invariant - a 'pass' check carries EMPTY remediation; only actionable
# 'fail' checks carry one. The non-forced self-test passes, so its remediation must
# be ""; the forced-fail self-test must still carry a non-empty remediation.
out="$(python3 "$PROBE" --self-test --report json)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
st=[c for c in d["checks"] if c["id"]=="self-test"]
assert st, "no self-test check"
c=st[0]
assert c["status"]=="pass", c["status"]
assert c["remediation"]=="", "pass leaked remediation: "+repr(c["remediation"])
' && pass "(l) self-test pass has empty remediation" \
  || fail "(l) self-test pass remediation"
out="$(PROBE_FORCE_FAIL=1 python3 "$PROBE" --self-test --report json || true)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=[c for c in d["checks"] if c["id"]=="self-test"][0]
assert c["status"]=="fail", c["status"]
assert c["remediation"], "forced fail must carry a remediation"
' && pass "(l) forced-fail self-test keeps remediation" \
  || fail "(l) forced-fail self-test remediation"

# (m) M1: the openssl proxy-port default must follow the proxy URL SCHEME so it
# agrees with curl/python/node. A port-less http:// proxy => :80 (NOT :8080);
# a port-less https:// proxy => :443; an explicit port is preserved verbatim.
python3 - <<'PY' && pass "(m) proxy-port default follows scheme" || fail "(m) proxy-port default follows scheme"
import importlib.util, urllib.parse
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def target(proxy_url):
    pu = urllib.parse.urlparse(proxy_url)
    return f"{pu.hostname}:{pu.port or m._default_port(pu.scheme)}"
assert target("http://proxy.corp") == "proxy.corp:80", target("http://proxy.corp")
assert target("https://proxy.corp") == "proxy.corp:443", target("https://proxy.corp")
assert target("http://proxy.corp:3128") == "proxy.corp:3128", target("http://proxy.corp:3128")
PY

# (n) M2: an IPv6-literal openssl target must bracket the host in -connect
# ([::1]:8443), which openssl requires; -servername keeps the bare host (no SNI
# for IP literals). A normal hostname stays unbracketed.
python3 - <<'PY' && pass "(n) openssl -connect brackets IPv6 literal" || fail "(n) openssl -connect brackets IPv6 literal"
import importlib.util
spec = importlib.util.spec_from_file_location("probe","images/proxy-ca-probe-ubi9/proxy-ca-probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cmd = m._openssl_cmd("::1", 8443, "proxy.corp", 8080)
i = cmd.index("-connect")
assert cmd[i+1] == "[::1]:8443", cmd[i+1]
j = cmd.index("-servername")
assert cmd[j+1] == "::1", cmd[j+1]
cmd2 = m._openssl_cmd("example.com", 443, "proxy.corp", 8080)
k = cmd2.index("-connect")
assert cmd2[k+1] == "example.com:443", cmd2[k+1]
PY

# (o) M3: the report's top-level `proxy` field must mirror _proxy() semantics:
# an empty HTTPS_PROXY falls through to https_proxy (dict.get only falls back
# on an ABSENT key, so a present-but-empty HTTPS_PROXY must not mask the value).
# HTTPS_PROXY= deliberately sets a PRESENT-but-empty var for the probe's env
# (the very condition under test), so the SC1007 empty-assignment hint is moot.
# shellcheck disable=SC1007
out="$(HTTPS_PROXY= https_proxy=http://p.test:8080 python3 "$PROBE" --self-test --report json)"
echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["proxy"] == "http://p.test:8080", repr(d["proxy"])
' && pass "(o) report proxy field mirrors _proxy()" \
  || fail "(o) report proxy field mirrors _proxy()"

if [ "$FAILURES" -gt 0 ]; then echo "${FAILURES} probe-report failure(s)"; exit 1; fi
echo "probe report contract OK"; exit 0
