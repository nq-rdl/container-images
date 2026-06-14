#!/usr/bin/env bash
# docker MITM acceptance for the proxy-ca-probe (issue #59).
# Proves the probe FAILS CLOSED against an untrusted MITM CA, and PASSES every
# toolchain once the MITM CA is folded into the system trust (Tier-2 update-ca-trust).
set -euo pipefail
[ -d images ] || { echo "ERROR: run from repo root"; exit 1; }
source tests/proxy-ca/lib/mitm.sh
RUNTIME="${RUNTIME:-docker}"
FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
NET="proxy-ca-net-$$"
OUT="$(mktemp -d)"   # per-run diagnostic reports; removed at the end only on success
cleanup() {
  mitm_down "$RUNTIME"
  "$RUNTIME" network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mitm_up "$RUNTIME"
FP="$(mitm_fingerprint)"
# This repo standardizes on Containerfile (not Dockerfile), so point -f at it.
"$RUNTIME" build -t proxy-ca-probe-ubi9:dev \
  -f images/proxy-ca-probe-ubi9/Containerfile images/proxy-ca-probe-ubi9

"$RUNTIME" network create "$NET" >/dev/null
"$RUNTIME" network connect "$NET" "$MITM_NAME"
# In-network probes always reach the mitm container on ITS port 8080 (below);
# MITM_PORT only changes the host publish mapping in mitm.sh, so this 8080 is
# correct and must not be "fixed" to MITM_PORT.
common=(--rm --network "$NET"
  -e TARGET_URL=https://example.com
  -e HTTPS_PROXY="http://${MITM_NAME}:8080" -e https_proxy="http://${MITM_NAME}:8080"
  -e "NO_PROXY=localhost,127.0.0.1" -e CORP_CA_FINGERPRINT="$FP")

# (a) WITHOUT the CA folded in -> probe must FAIL CLOSED on the untrusted MITM:
#     both a non-zero exit AND the system-bundle trust check reporting the corp CA
#     is not folded in. Asserting the trust reason (not just "any non-zero exit")
#     stops a flaky egress error from false-PASSing (a) for the wrong reason.
if "$RUNTIME" run "${common[@]}" proxy-ca-probe-ubi9:dev --report json \
     >"$OUT/r_nocafold.json" 2>"$OUT/r_nocafold.err"; then
  fail "(a) probe should FAIL when corp CA is not trusted (see $OUT)"
elif python3 -c '
import json, sys
d=json.load(open(sys.argv[1]))
sb=[c for c in d["checks"] if c["id"]=="system-bundle"]
assert sb and sb[0]["status"]=="fail", \
    "system-bundle should fail when corp CA not folded: %r" % sb
' "$OUT/r_nocafold.json"; then
  pass "(a) probe detects untrusted MITM CA"
else
  fail "(a) probe exited non-zero but system-bundle trust check did not fail (see $OUT)"
fi

# (b) WITH the CA folded in. Tier-2 `update-ca-trust extract` (run as root here)
#     regenerates BOTH the PEM bundle and the system Java cacerts the JDK symlinks to.
#     Fix 1: the JVM ignores HTTPS_PROXY, so route Java through the proxy explicitly via
#       JAVA_TOOL_OPTIONS (otherwise its "pass" wouldn't be a through-proxy result).
#     Fix 2: git SKIPs unless TARGET_GIT_URL is a real remote -> set one so (b2) can
#       require a git PASS.
if "$RUNTIME" run "${common[@]}" \
  -e PROBE_CHECK_JAVA=1 \
  -e TARGET_GIT_URL=https://github.com/nq-rdl/container-images.git \
  -e JAVA_TOOL_OPTIONS="-Dhttps.proxyHost=${MITM_NAME} -Dhttps.proxyPort=8080 -Dhttp.proxyHost=${MITM_NAME} -Dhttp.proxyPort=8080" \
  -v "$(pwd)/${CA_DIR}/corp-ca.crt:/etc/pki/ca-trust/source/anchors/corp-ca.crt:ro" \
  --user 0 --entrypoint /bin/bash proxy-ca-probe-ubi9:dev \
  -c 'update-ca-trust extract && proxy-ca-probe --report json' \
  >"$OUT/r_cafold.json" 2>"$OUT/r_cafold.err"; then
  pass "(b) probe passes with CA folded in"
else
  fail "(b) probe should pass with CA trusted (see $OUT)"
fi

# (b2) every toolchain verified THROUGH the proxy with the CA trusted.
if python3 -c '
import json, sys
d=json.load(open(sys.argv[1]))
assert d["summary"]["failed"]==0, d["summary"]
tc={c["toolchain"] for c in d["checks"] if c["category"]=="egress" and c["status"]=="pass"}
need={"openssl","curl","python","node","git","java"}
assert need <= tc, "missing: %s" % (need - tc)
' "$OUT/r_cafold.json"; then
  pass "(b2) all six toolchains verified through proxy"
else
  fail "(b2) missing toolchain pass (see $OUT/r_cafold.json, $OUT/r_cafold.err)"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} docker MITM failure(s); diagnostic reports kept in $OUT"
  exit 1
fi
rm -rf "$OUT"   # success: drop diagnostics (kept above on failure)
echo "docker MITM acceptance OK"
