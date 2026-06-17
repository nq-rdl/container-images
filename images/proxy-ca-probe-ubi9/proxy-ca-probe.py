#!/usr/bin/env python3
"""proxy-ca-probe: verify the issue-#59 proxy + CA-trust contract per toolchain.

Modes:
  --self-test    run offline; exercise the report machinery (CI/hermetic).
  (default)      run live checks against TARGET_URL through HTTPS_PROXY.

Report:
  --report json  machine-readable (default); --report human  summary report.

Exit code: 0 iff no check has status 'fail'. Each 'fail' is a filable bug:
the JSON 'remediation' field is the suggested fix.
"""
import argparse, json, os, sys
import shutil, subprocess, urllib.request, urllib.parse

SCHEMA_VERSION = "1"
CONTRACT_VARS = {
    "SSL_CERT_FILE": "/etc/pki/tls/certs/ca-bundle.crt",
    "REQUESTS_CA_BUNDLE": "/etc/pki/tls/certs/ca-bundle.crt",
    "CURL_CA_BUNDLE": "/etc/pki/tls/certs/ca-bundle.crt",
    "PIP_CERT": "/etc/pki/tls/certs/ca-bundle.crt",
    "GIT_SSL_CAINFO": "/etc/pki/tls/certs/ca-bundle.crt",
}
SYSTEM_BUNDLE = "/etc/pki/tls/certs/ca-bundle.crt"

HELPERS = os.environ.get(
    "PROBE_HELPERS_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "helpers"))

try:
    CMD_TIMEOUT = int(os.environ.get("PROBE_CMD_TIMEOUT", "30"))
except ValueError:
    CMD_TIMEOUT = 30


def check(checks, *, id, toolchain, category, status, expected="", actual="",
          detail="", remediation=""):
    checks.append(dict(id=id, toolchain=toolchain, category=category,
                       status=status, expected=expected, actual=actual,
                       detail=detail, remediation=remediation))


def run_self_test(checks):
    forced = os.environ.get("PROBE_FORCE_FAIL") == "1"
    # Invariant: a 'pass' check carries empty remediation; only the forced 'fail'
    # gets an (actionable) remediation.
    check(checks, id="self-test", toolchain="probe", category="meta",
          status="fail" if forced else "pass",
          detail="forced failure" if forced else "self-test ok",
          remediation="unset PROBE_FORCE_FAIL to clear this forced self-test failure"
          if forced else "")


def build_report(checks):
    summary = {"total": len(checks),
               "passed": sum(c["status"] == "pass" for c in checks),
               "failed": sum(c["status"] == "fail" for c in checks),
               "skipped": sum(c["status"] == "skip" for c in checks)}
    return {"schema_version": SCHEMA_VERSION,
            "target_url": os.environ.get("TARGET_URL", ""),
            "proxy": os.environ.get("HTTPS_PROXY", os.environ.get("https_proxy", "")),
            "summary": summary, "checks": checks}


def render_human(report):
    lines = [f"proxy-ca-probe  target={report['target_url'] or '(none)'}  "
             f"proxy={report['proxy'] or '(none)'}"]
    for c in report["checks"]:
        mark = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"}[c["status"]]
        lines.append(f"  [{mark}] {c['toolchain']:>8} {c['id']:<22} {c['detail']}")
        if c["status"] == "fail" and c["remediation"]:
            lines.append(f"         fix: {c['remediation']}")
    s = report["summary"]
    lines.append(f"summary: {s['passed']} passed, {s['failed']} failed, "
                 f"{s['skipped']} skipped, {s['total']} total")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--report", choices=["json", "human"], default="json")
    args = ap.parse_args()

    checks = []
    if args.self_test:
        run_self_test(checks)
    else:
        run_live_checks(checks)

    report = build_report(checks)
    if args.report == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_human(report))
    sys.exit(1 if report["summary"]["failed"] else 0)


def _normalize_fp(s):
    return s.replace(":", "").lower()


def _as_text(x):
    # TimeoutExpired buffers stdout/stderr as bytes even under text=True, so
    # normalize to str before concatenating the synthetic timeout message.
    if isinstance(x, bytes):
        return x.decode("utf-8", "replace")
    return x or ""


def _run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=CMD_TIMEOUT, **kw)
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(cmd, 124, _as_text(e.stdout),
                                           _as_text(e.stderr) + " timed out")
    except OSError as e:
        return subprocess.CompletedProcess(cmd, 127, "", str(e))


def _proxy():
    return os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")


def _openssl_cmd(host, port, proxy_host, proxy_port, proxy_user=None,
                 proxy_pass=None):
    # `-proxy` takes a BARE host:port (no scheme/creds). Credentials route to
    # -proxy_user/-proxy_pass; -proxy_pass is a password SOURCE, so the decoded
    # password is wrapped as "pass:<password>" (a bare password makes OpenSSL
    # abort with "Invalid password argument" before connecting).
    cmd = ["openssl", "s_client", "-connect", f"{host}:{port}",
           "-servername", host, "-proxy", f"{proxy_host}:{proxy_port}",
           "-verify_return_error", "-brief"]
    if proxy_user:
        cmd += ["-proxy_user", proxy_user,
                "-proxy_pass", "pass:" + (proxy_pass or "")]
    return cmd


def _curl_cmd(target):
    # TLS/proxy-only probe: NO -f/--fail. An HTTP 4xx from a reachable target means
    # TLS + proxy egress already succeeded, so -f would file a false CA/proxy bug.
    # Keep -sS so real connection/TLS errors still produce a nonzero exit.
    return ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", target]


def run_live_checks(checks):
    target = os.environ.get("TARGET_URL")
    expected_fp = _normalize_fp(os.environ.get("CORP_CA_FINGERPRINT", ""))

    # 1. env contract: each var set + (bundle-pointing ones) file exists, non-empty
    for var, want in CONTRACT_VARS.items():
        got = os.environ.get(var)
        if got != want:
            check(checks, id=f"env-{var}", toolchain="env", category="contract",
                  status="fail", expected=want, actual=got or "(unset)",
                  detail=f"{var} not baked to contract value",
                  remediation=f"add `ENV {var}={want}` to the image (block C-1)")
            continue
        ok = os.path.isfile(got) and os.path.getsize(got) > 0
        check(checks, id=f"env-{var}", toolchain="env", category="contract",
              status="pass" if ok else "fail", expected=want, actual=got,
              detail="set + path present" if ok else "path missing/empty",
              remediation="" if ok else f"ensure {got} exists in the image (invariant C-2)")

    # 2. NODE_EXTRA_CA_CERTS may point at a mount path (absent is tolerated)
    nec = os.environ.get("NODE_EXTRA_CA_CERTS")
    check(checks, id="env-NODE_EXTRA_CA_CERTS", toolchain="env", category="contract",
          status="pass" if nec else "fail", expected="(a conventional anchor path)",
          actual=nec or "(unset)", detail="set" if nec else "unset",
          remediation="" if nec else "bake NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt")

    # 3. always-present system bundle exists + (optional) contains the corp CA
    bundle_ok = os.path.isfile(SYSTEM_BUNDLE) and os.path.getsize(SYSTEM_BUNDLE) > 0
    detail = "present" if bundle_ok else "MISSING - every TLS call will fail"
    rem = "" if bundle_ok else "install ca-certificates / stage the bundle into the final image"
    if bundle_ok and expected_fp:
        present = expected_fp in _bundle_fingerprints(SYSTEM_BUNDLE)
        if not present:
            bundle_ok, detail, rem = False, "corp CA not folded into the bundle", \
                "mount/fold the corp CA into the bundle (Tier 1/2)"
    check(checks, id="system-bundle", toolchain="openssl", category="trust",
          status="pass" if bundle_ok else "fail", expected=SYSTEM_BUNDLE,
          actual=SYSTEM_BUNDLE, detail=detail, remediation=rem)

    if not target or not _proxy():
        check(checks, id="egress", toolchain="probe", category="meta", status="skip",
              detail="TARGET_URL/HTTPS_PROXY unset; ran contract checks only",
              remediation="set TARGET_URL and HTTPS_PROXY to run egress checks")
        return

    host = urllib.parse.urlparse(target).hostname
    port = urllib.parse.urlparse(target).port or 443
    if not host:
        check(checks, id="target-url", toolchain="probe", category="meta",
              status="fail", expected="https://host[:port]/...", actual=target,
              detail="TARGET_URL has no hostname (invalid URL or missing scheme)",
              remediation="set TARGET_URL to an absolute https URL, e.g. https://example.com")
        return
    pu = urllib.parse.urlparse(_proxy())

    # 4. openssl s_client through the proxy. `-proxy` takes a BARE host:port, so we
    #    parse host/port from the URL and route any credentials to -proxy_user/
    #    -proxy_pass instead of stripping them (else an authenticated corp proxy
    #    looks like a TLS-verify failure - a distinct failure mode).
    if shutil.which("openssl"):
        cmd = _openssl_cmd(
            host, port, pu.hostname, pu.port or 8080,
            proxy_user=urllib.parse.unquote(pu.username) if pu.username else None,
            proxy_pass=urllib.parse.unquote(pu.password or "") if pu.username else None)
        r = _run(cmd, input="")
        _verdict(checks, "openssl", "tls-via-proxy", r.returncode == 0,
                 r.stderr.strip()[-200:],
                 "openssl chain verify failed via proxy "
                 "(check proxy-auth vs CA-verify separately)")

    # 5. curl
    if shutil.which("curl"):
        r = _run(_curl_cmd(target))
        _verdict(checks, "curl", "https-via-proxy", r.returncode == 0,
                 (r.stdout + r.stderr).strip()[-200:], "curl TLS verify failed (CURL_CA_BUNDLE / proxy)")

    # 6. python requests (or urllib if requests absent)
    _verdict(checks, "python", "https-via-proxy", *_python_https(target))

    # 7. node
    if shutil.which("node"):
        r = _run(["node", os.path.join(HELPERS, "node-tls-probe.js")])
        _verdict(checks, "node", "tls-via-proxy", r.returncode == 0,
                 (r.stdout + r.stderr).strip()[-200:], "Node TLS not authorized (NODE_EXTRA_CA_CERTS)")

    # 8. git - only when a REAL git endpoint is given. Defaulting to TARGET_URL
    #    (e.g. https://example.com) is not a git remote and would file a false bug.
    gurl = os.environ.get("TARGET_GIT_URL")
    if shutil.which("git") and gurl:
        r = _run(["git", "ls-remote", gurl])
        _verdict(checks, "git", "https-via-proxy", r.returncode == 0,
                 r.stderr.strip()[-200:], "git TLS verify failed (GIT_SSL_CAINFO / http.proxy)")
    elif shutil.which("git"):
        check(checks, id="https-via-proxy", toolchain="git", category="egress",
              status="skip", detail="TARGET_GIT_URL unset (TARGET_URL is not a git remote)",
              remediation="set TARGET_GIT_URL to a real https git endpoint to exercise git")

    # 9. java - the JVM is the documented EXCEPTION (C-4): it reads neither the PEM
    #    bundle nor HTTP_PROXY. Whether Java is "covered" depends on the deployment
    #    (Tier-2 system cacerts, or a mounted keystore + JAVA_TOOL_OPTIONS), so the
    #    caller signals intent with PROBE_CHECK_JAVA. Default = SKIP, so a PEM-only
    #    Tier-1 run does not file a false Java bug. Run the PRECOMPILED class so
    #    JRE-only target images (no javac) can execute it.
    if shutil.which("java") and os.environ.get("PROBE_CHECK_JAVA"):
        r = _run(["java", "-cp", HELPERS, "TlsProbe"])
        _verdict(checks, "java", "https-via-proxy", r.returncode == 0,
                 (r.stdout + r.stderr).strip()[-200:],
                 "JVM trust/proxy not wired (system cacerts, or JAVA_TOOL_OPTIONS keystore + proxy props, see C-4)")
    elif shutil.which("java"):
        check(checks, id="https-via-proxy", toolchain="java", category="egress",
              status="skip", detail="PROBE_CHECK_JAVA unset (JVM out of scope for PEM-only Tier-1, C-4)",
              remediation="once Java trust is configured (Tier-2 cacerts or keystore+JAVA_TOOL_OPTIONS), set PROBE_CHECK_JAVA=1")


def _verdict(checks, toolchain, id, ok, detail, fail_remediation):
    check(checks, id=id, toolchain=toolchain, category="egress",
          status="pass" if ok else "fail", detail=detail,
          remediation="" if ok else fail_remediation)


def _python_https(target):
    try:
        with urllib.request.urlopen(target, timeout=15) as resp:
            return True, f"status={resp.status}", ""
    except Exception as e:  # noqa: BLE001 - report any TLS/proxy failure verbatim
        return False, str(e)[-200:], "python TLS verify failed (REQUESTS_CA_BUNDLE/SSL_CERT_FILE)"


def _bundle_fingerprints(path):
    fps = set()
    # Split bundle into individual certs and fingerprint each.
    try:
        with open(path) as fh:
            data = fh.read()
        for block in data.split("-----END CERTIFICATE-----"):
            if "BEGIN CERTIFICATE" not in block:
                continue
            pem = block + "-----END CERTIFICATE-----\n"
            r = _run(["openssl", "x509", "-noout", "-fingerprint", "-sha256"], input=pem)
            if r.returncode == 0:
                fps.add(_normalize_fp(r.stdout.split("=")[-1].strip()))
    except Exception:
        # Best-effort: fingerprinting is an optional cross-check, so any read/parse
        # failure (missing bundle, unreadable file, malformed PEM) returns whatever
        # was collected so far - an empty or partial set - instead of crashing the probe.
        pass
    return fps


if __name__ == "__main__":
    main()
