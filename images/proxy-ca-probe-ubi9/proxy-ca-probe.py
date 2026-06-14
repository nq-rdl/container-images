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

SCHEMA_VERSION = "1"
CONTRACT_VARS = {
    "SSL_CERT_FILE": "/etc/pki/tls/certs/ca-bundle.crt",
    "REQUESTS_CA_BUNDLE": "/etc/pki/tls/certs/ca-bundle.crt",
    "CURL_CA_BUNDLE": "/etc/pki/tls/certs/ca-bundle.crt",
    "PIP_CERT": "/etc/pki/tls/certs/ca-bundle.crt",
    "GIT_SSL_CAINFO": "/etc/pki/tls/certs/ca-bundle.crt",
}
SYSTEM_BUNDLE = "/etc/pki/tls/certs/ca-bundle.crt"


def check(checks, *, id, toolchain, category, status, expected="", actual="",
          detail="", remediation=""):
    checks.append(dict(id=id, toolchain=toolchain, category=category,
                       status=status, expected=expected, actual=actual,
                       detail=detail, remediation=remediation))


def run_self_test(checks):
    forced = os.environ.get("PROBE_FORCE_FAIL") == "1"
    check(checks, id="self-test", toolchain="probe", category="meta",
          status="fail" if forced else "pass",
          detail="forced failure" if forced else "self-test ok",
          remediation="n/a")


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
        run_live_checks(checks)  # defined fully in Task A2

    report = build_report(checks)
    if args.report == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_human(report))
    sys.exit(1 if report["summary"]["failed"] else 0)


def run_live_checks(checks):  # replaced in Task A2
    check(checks, id="not-implemented", toolchain="probe", category="meta",
          status="skip", detail="live checks added in Task A2", remediation="")


if __name__ == "__main__":
    main()
