# Proxy + CA-Trust Management Implementation Plan (Issue #59)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a single, predictable proxy-env + CA-trust contract across every image in the catalog, and a dedicated amd64 UBI diagnostic image that *proves* the contract works behind a TLS-inspecting corporate proxy and reports failures as filable bugs.

**Architecture:** Bake the *ecosystem CA env vars* (pointing at the always-present system bundle) into all 21 buildable Containerfiles; deliver corporate CA material at runtime via three tiers (mounted bundle / anchors+`update-ca-trust` / `openssl` fetch) with the JVM as a documented exception; validate the whole thing locally against a real MITM forward proxy (mitmproxy) under **docker** and **k3d** before anything is called "uniform." A new `proxy-ca-probe-ubi9` image is both the TDD fixture and the field instrument for the corp environment.

**Tech Stack:** UBI9 / ubi-minimal / ubi-micro Containerfiles, `docker buildx bake`, k3d (k3s v1.31), kubectl, mitmproxy (forward proxy + throwaway CA), bash test harness (`fail()/pass()` idiom), conftest/OPA + shell policy tests, changie, pixi tasks.

**Why this is WIP until corp validation:** the dev environment here has **no** corporate proxy. Every tier and toolchain is validated locally with a *simulated* MITM proxy, but Tier-1 mount mechanics on RKE2/OpenShift and the real corporate inspection CA can only be confirmed on the corp env. The `proxy-ca-probe-ubi9` image exists to close that gap: run it on corp, collect its JSON report, file each FAIL as a bug. The PR stays **draft** until Milestone E reports green on corp.

---

## Survey findings this plan is built on (read before starting)

Verified by a 27-agent survey of the repo on 2026-06-14. Key facts:

1. **No image currently bakes *any* CA env var.** A grep for `SSL_CERT_FILE|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|PIP_CERT|GIT_SSL_CAINFO|NODE_EXTRA_CA_CERTS|SSL_CERT_DIR` across `images/**/Containerfile` returns nothing. Milestone B is therefore building a convention from zero; the static test in Task B1 is **red** until the Containerfiles are edited.
2. **Build is filesystem-auto-discovered.** `.github/workflows/build.yml`'s `discover` job globs `images/*/Containerfile`; any dir with a `Containerfile` and **no** `bake_target` in its `image.yaml` is built automatically as an amd64 matrix image. **Adding the probe image requires zero workflow edits.** Chained images (datascience, jamovi) are excluded via `bake_target` and built by `docker-bake.hcl`.
3. **There is no global ENV/build-arg injection point.** Common ENV must be added **per-Containerfile** (21 files). This is the bulk of Milestone B and the reason for the coverage test.
4. **Three entrypoint families** (drives *where* CA work can run):
   - **leaf-exec** (no shell at startup; CA trust must be **build-time**): `bun-ubi9`, `dbt-ubi9`, `python-ubi9`, `r-base-ubi9`, `zulu17-jdk-ubi9`, `zulu17-jre-headless-ubi9`, `zulu21-jdk-ubi9`, `zulu21-jre-headless-ubi9`, `jamovi-ubi9` (runs as root but execs `python3` directly).
   - **notebook-hooks** (root `before-notebook.d` hook available → Tier-2 capable): `docker-stacks-foundation-ubi9`, `base-notebook-ubi9`, `minimal-notebook-ubi9`, `scipy-notebook-ubi9`.
   - **bespoke-entrypoint**: `pyspark-ubi9` (USER spark, no root hook), `spark-ubi9` (USER spark, no root hook), `spark-operator-ubi9` (USER 185, Go static, **no JVM**), `starrocks-allin1-ubi9` / `starrocks-be-ubi9` / `starrocks-cn-ubi9` / `starrocks-fe-ubi9` (root; allin1 & be have a root entrypoint where a hook can be added). Plus `jamovi-deps-ubi9` (intermediate, runs root, base-inherited).
5. **Java images (JVM exception applies):** `zulu17-jdk`, `zulu17-jre-headless`, `zulu21-jdk`, `zulu21-jre-headless`, `pyspark-ubi9`, `spark-ubi9`, `starrocks-allin1/be/cn/fe-ubi9` = **10 images**. `spark-operator-ubi9` is **Go, not Java**.
6. **Zulu trust gap (Open Question #1 — resolved in this plan):** the zulu images do **not** install `ca-certificates` and do **not** generate `/etc/pki/ca-trust/extracted/java/cacerts`. The JRE falls back to Azul's bundled `${JAVA_HOME}/lib/security/cacerts`. So a system `update-ca-trust` does **not** reach Java today. Task B6 fixes this (install `ca-certificates`, extract, symlink the JDK keystore to the system-extracted one).
7. **`ubi-micro` trap:** `dbt-ubi9`'s final stage is `ubi-micro` with no package manager. Must verify `/etc/pki/tls/certs/ca-bundle.crt` exists in the final image; if not, the `ca-certificates` content must be staged in from the `runtime-rootfs` (`ubi:9.5`) stage. Task B5 covers this.
8. **`node-ubi9` is an empty stub** (only a `.gitignore`). It has no Containerfile, so `discover` skips it and the coverage test must skip it too. Out of scope here.
9. **Tests split in two:** static policy tests run in **CI** (`policy.yml`, `validate-base-pins.yml`); `scripts/smoke-test.sh` + `scripts/trivy-scan.sh` are **local pre-push only** (not CI). The CA-env coverage test (B1) is static → CI. The runtime MITM test (Milestone C) is smoke-family → local, with an optional CI lane noted.
10. **Policy gates a new image must pass:** UBI base (`policy/base_image.rego`), 5 OCI labels incl. `vendor="Research Data Laboratory"` exact (`policy/labels.rego`), tags match `X.Y.Z|X.Y|latest` (`policy/image-meta/tags.rego`), external base digest-pinned (`tests/test-base-images-pinned.sh`), hadolint `warning` threshold, a changie fragment on push, no fixable CRITICAL/HIGH (trivy, pre-push). **Do NOT add a dependabot docker entry** — `CONTRIBUTING.md` is stale there; `base-drift.yml` handles base bumps.
11. **The "38 packages":** GHCR has 40 container packages; minus `documentation` and `fhir-jit` = 38. The active **source** catalog is the 21 `-ubi9` dirs. The 19 legacy non-`-ubi9` packages (`python`, `bun`, `spark`, …) are **not built from this repo** (superseded aliases/old publishes). This plan applies the contract to the 21 source images; legacy-package cleanup is a decision in the Open Decisions section.

---

## The contract (single source of truth for the whole plan)

### C-1: The baked CA env block (identical in every image)

These vars are **harmless when no corp CA is present** (they point at the normal public bundle), so they are baked unconditionally. All of them point at the **always-present** consolidated system bundle, *except* `NODE_EXTRA_CA_CERTS`, which is the one var that *appends* and *tolerates an absent file*, so it is the only one safe to bake at a conventional mount path.

```dockerfile
# --- issue #59: uniform CA-trust env contract -------------------------------
# Every var below points at the ALWAYS-PRESENT consolidated system bundle so a
# missing mount can never zero out trust. The corporate inspection CA is folded
# INTO that bundle at runtime (see docs/proxy-and-ca.md, Tiers 1-3).
# NODE_EXTRA_CA_CERTS is the sole exception: it appends to Node's built-ins and
# tolerates an absent file, so it may point at a conventional anchor mount path.
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    CURL_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PIP_CERT=/etc/pki/tls/certs/ca-bundle.crt \
    GIT_SSL_CAINFO=/etc/pki/tls/certs/ca-bundle.crt \
    NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt
# ----------------------------------------------------------------------------
```

**Placement rule:** add this block in the **final image stage**, while still `root` if the image switches users, and **before** the final `USER`/`ENTRYPOINT`. For chained images the block is inherited from the base — child images do **not** repeat it (the coverage test in B1 treats `ARG BASE_CONTAINER` images as inheriting).

> **Why no `SSL_CERT_DIR`?** (adversarial-review finding, resolved.) `SSL_CERT_DIR` is meant to point at an OpenSSL **hashed-symlink** directory (`c_rehash` output), not a directory that merely contains the bundle. On UBI that hashed dir is `/etc/pki/ca-trust/extracted/openssl/`, *not* `/etc/pki/tls/certs`. Baking `SSL_CERT_DIR=/etc/pki/tls/certs` is at best redundant with `SSL_CERT_FILE` and at worst a footgun that a weak "is a directory" test would green-light. **Decision:** drop `SSL_CERT_DIR` from the baked contract entirely. `SSL_CERT_FILE` (the always-present consolidated bundle, into which the corp CA is folded) is OpenSSL's authoritative source and is sufficient. This is a documented deviation from the issue's variable table; note it in `docs/proxy-and-ca.md`.

### C-2: Always-present bundle invariant

`/etc/pki/tls/certs/ca-bundle.crt` is a symlink to `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` and is present on `ubi9/ubi` and `ubi9/ubi-minimal`. It must be verified present and non-empty on **every** final image (including `ubi-micro`). The contract vars are useless if this file is absent.

### C-3: The three tiers (runtime delivery of the corporate CA)

- **Tier 1 (recommended, leaf-safe, no root, no rebuild):** platform mounts a *complete* bundle (public roots **+** corp CA) **as a whole projected directory at a stable path** — never a `subPath` single-file overmount (subPath does not live-update; CA rotation would silently stale). **The mounted directory overlays `/etc/pki/ca-trust/extracted/pem/` and the projected file MUST be named `tls-ca-bundle.pem`** (set the ConfigMap `items[].path: tls-ca-bundle.pem`), because the always-present `/etc/pki/tls/certs/ca-bundle.crt` symlink resolves to `…/extracted/pem/tls-ca-bundle.pem`. A wrong key name leaves the symlink dangling and zeroes out trust — exactly the maybe-absent-path trap, one layer down. **Every Tier-1 acceptance test MUST assert, inside the pod, that `readlink -f /etc/pki/tls/certs/ca-bundle.crt` resolves to a non-empty file** that contains the corp CA fingerprint. (Adversarial-review finding, resolved.)
- **Tier 2 (`CA_BUNDLE=1`, root + writable rootfs):** raw corp PEM mounted at `/etc/pki/ca-trust/source/anchors/corp-ca.crt`; a root startup hook runs `update-ca-trust extract`. Only for images with a root entrypoint hook (notebook `before-notebook.d`, starrocks-allin1/be `entrypoint.sh`). **Never** the leaf images.
- **Tier 3 (`CA_BUNDLE=1`, no mount, dev/laptop only, opt-in):** probe the proxy with `openssl s_client` and extract the inspection CA. Trust-on-first-use; startup latency/crashloop risk; needs root + writable trust dir. Must parse `host:port` out of a possibly-credentialed proxy URL.

### C-4: JVM exception

Java reads neither PEM bundles nor `HTTP_PROXY`. Decisions for this plan:
- **Trust:** make every Java image's JDK keystore resolve to the **system-extracted** Java cacerts so build-time/Tier-2 `update-ca-trust` reaches Java too (Task B6). Under leaf Tier-1 (zulu), Java additionally needs a **mounted keystore + `JAVA_TOOL_OPTIONS`**, and because a missing `-Djavax.net.ssl.trustStore` file *breaks* Java TLS, that option is **platform-set in pod env**, never baked at a maybe-absent path.
- **Proxy:** translate proxy config to system properties (`-Dhttps.proxyHost`/`-Dhttps.proxyPort`/`-Dhttp.nonProxyHosts`) via `JAVA_TOOL_OPTIONS`, **platform-set** (not baked).
- **Acceptance:** verified with **Zulu and Spark** smoke tests (Task C5) before "uniform" wording is accepted for Java.

### C-5: Proxy env

Nothing is baked for the main process — `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` arrive via pod `env:`/`-e`. Document **both cases** (`HTTP_PROXY` *and* `http_proxy`; curl reads only lowercase — httpoxy mitigation). Recommended `NO_PROXY` default: `localhost,127.0.0.1,.svc,.cluster.local` + internal CIDRs. Ship an **optional** `/etc/profile.d/proxy.sh` (interactive `kubectl exec`/notebook-terminal convenience only) on images that have a shell.

---

## File structure (what gets created / modified)

**Created:**
- `images/proxy-ca-probe-ubi9/Containerfile` — the diagnostic image (full `ubi9/ubi`, amd64).
- `images/proxy-ca-probe-ubi9/image.yaml` — metadata (auto-discovered, amd64-only).
- `images/proxy-ca-probe-ubi9/README.md` — usage + report schema.
- `images/proxy-ca-probe-ubi9/proxy-ca-probe.py` — orchestrator; runs every toolchain check, emits JSON + human report.
- `images/proxy-ca-probe-ubi9/helpers/node-tls-probe.js` — Node CONNECT+TLS trust probe (dependency-free).
- `images/proxy-ca-probe-ubi9/helpers/TlsProbe.java` — Java TLS probe (precompiled at build to `TlsProbe.class`, run via `java -cp`).
- `images/proxy-ca-probe-ubi9/smoke-cmd` — `--self-test` (smoke harness runs the probe in offline self-test mode).
- `tests/test-ca-env-vars.sh` — static coverage test: every buildable image bakes C-1 (or inherits it).
- `tests/test-proxy-ca-probe-report.sh` — hermetic test of the probe's JSON schema/exit codes (stubbed toolchains).
- `tests/proxy-ca/docker-compose.yaml` — mitmproxy + probe + representative catalog images.
- `tests/proxy-ca/run-docker.sh` — brings up the MITM fixture, runs probe + catalog images, asserts.
- `tests/proxy-ca/k3d/` — `00-namespace.yaml`, `10-proxy.yaml`, `20-ca-configmap.yaml`, `30-probe-job.yaml`, `40-readonly-nonroot-job.yaml`.
- `tests/proxy-ca/run-k3d.sh` — creates k3d cluster, imports images, applies manifests, asserts Job success + reads report; rotation sub-test.
- `tests/proxy-ca/lib/mitm.sh` — shared fixture helpers (start/stop proxy, extract CA, fingerprint).
- `scripts/proxy-ca-test.sh` — orchestrates `run-docker.sh` + `run-k3d.sh` (pixi `proxy-ca-test`, opt-in pre-push).
- `docs/proxy-and-ca.md` — the contract + per-runtime example manifests (docker/podman/k3s/RKE2/OpenShift) + JVM exception + tier table.
- One changie fragment per milestone (`.changes/unreleased/Added-*.yaml`).

**Modified:**
- 21 `images/*/Containerfile` — add the C-1 block (Milestone B), plus Java wiring (B6) and Tier-2 hooks (B7) where applicable.
- `pyproject.toml` — add pixi tasks `policy-check-ca-env`, `proxy-ca-test`; add `policy-check-ca-env` to the `policy-check` aggregate.
- `.github/workflows/policy.yml` — add a step running `tests/test-ca-env-vars.sh`.
- `.pre-commit-config.yaml` — (optional) add `proxy-ca-test` as a pre-push hook behind `SKIP_PROXY_CA=1`.
- `docs/superpowers/plans/2026-06-14-proxy-ca-management.md` — this file.

---

## Milestones

- **A. Probe image + local MITM fixture (TDD).** The instrument and the test rig. Independently shippable.
- **B. Contract rollout across the 21 images (TDD via coverage test).** The bulk. Independently shippable behind the coverage test.
- **C. Runtime acceptance on docker + k3d (TDD).** Proves trust + proxy egress + non-root/read-only + rotation + JVM.
- **D. Docs.** `docs/proxy-and-ca.md` with per-runtime manifests.
- **E. Corp-env validation loop.** Run the probe on corp, file bugs, un-WIP the PR.

Each milestone ends green and is committed. A → B → C is the natural order; A and B can proceed in parallel by two workers because B's coverage test (B1) does not depend on A.

---

## Milestone A — Probe image + MITM fixture

### Task A1: Hermetic test of the probe's report contract (RED first)

**Files:**
- Test: `tests/test-proxy-ca-probe-report.sh`
- (drives) Create: `images/proxy-ca-probe-ubi9/proxy-ca-probe.py`

- [ ] **Step 1: Write the failing test**

`tests/test-proxy-ca-probe-report.sh`:

```bash
#!/usr/bin/env bash
# Hermetic test of images/proxy-ca-probe-ubi9/proxy-ca-probe.py.
# Runs the probe in --self-test mode (no network): it must emit schema-valid
# JSON, set per-check status, and exit 0 only when every non-skipped check
# passed. Toolchain calls are stubbed via PROBE_STUB_DIR on PATH.
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
```

- [ ] **Step 2: Run it; verify it fails because the probe does not exist yet**

Run: `bash tests/test-proxy-ca-probe-report.sh`
Expected: FAIL — `python3: can't open file '.../proxy-ca-probe.py'`.

- [ ] **Step 3: Write the minimal probe to pass (orchestrator + self-test mode)**

`images/proxy-ca-probe-ubi9/proxy-ca-probe.py` (minimal core; real toolchain checks added in A2):

```python
#!/usr/bin/env python3
"""proxy-ca-probe: verify the issue-#59 proxy + CA-trust contract per toolchain.

Modes:
  --self-test    run offline; exercise the report machinery (CI/hermetic).
  (default)      run live checks against TARGET_URL through HTTPS_PROXY.

Report:
  --report json  machine-readable (default); --report human  summary table.

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
            lines.append(f"         ↳ fix: {c['remediation']}")
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
        run_live_checks(checks)  # defined in Task A2

    report = build_report(checks)
    if args.report == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_human(report))
    sys.exit(1 if report["summary"]["failed"] else 0)


if __name__ == "__main__":
    main()
```

> Note: `run_live_checks` is referenced but only defined in A2. For A1 to pass, add a stub at the bottom of the module now:
> ```python
> def run_live_checks(checks):  # replaced in Task A2
>     check(checks, id="not-implemented", toolchain="probe", category="meta",
>           status="skip", detail="live checks added in Task A2", remediation="")
> ```

- [ ] **Step 4: Run the test; verify it passes**

Run: `bash tests/test-proxy-ca-probe-report.sh`
Expected: `PASS` on (a)(b)(c), then `probe report contract OK`.

- [ ] **Step 5: Register the pixi task and commit**

Add to `pyproject.toml` `[tool.pixi.tasks]`: `test-proxy-ca-probe-report = "bash tests/test-proxy-ca-probe-report.sh"` and add it to the `policy-check` aggregate `depends-on` (it is offline/hermetic). Then:

```bash
chmod +x images/proxy-ca-probe-ubi9/proxy-ca-probe.py
git add tests/test-proxy-ca-probe-report.sh images/proxy-ca-probe-ubi9/proxy-ca-probe.py pyproject.toml
git commit -m "test(probe): hermetic report-contract test + minimal probe skeleton"
```

### Task A2: Live per-toolchain checks (TDD against the MITM fixture)

**Files:**
- Create: `tests/proxy-ca/lib/mitm.sh`
- Modify: `images/proxy-ca-probe-ubi9/proxy-ca-probe.py` (replace `run_live_checks`)
- Create: `images/proxy-ca-probe-ubi9/helpers/node-tls-probe.js`, `images/proxy-ca-probe-ubi9/helpers/TlsProbe.java`
- Test: extend `tests/proxy-ca/run-docker.sh` (Task A4) is the integration gate; A2's unit gate is below.

- [ ] **Step 1: Write the MITM fixture helper** (used by every runtime test)

`tests/proxy-ca/lib/mitm.sh`:

```bash
#!/usr/bin/env bash
# Shared MITM forward-proxy fixture using mitmproxy. Brings up a TLS-inspecting
# forward proxy with its own throwaway CA, mirroring a corporate proxy.
# Pinned by digest so CI/local match.
set -euo pipefail
MITM_IMAGE="docker.io/mitmproxy/mitmproxy@sha256:REPLACE_WITH_PINNED_DIGEST"
MITM_NAME="${MITM_NAME:-proxy-ca-mitm}"
MITM_PORT="${MITM_PORT:-8080}"
CA_DIR="${CA_DIR:-tests/proxy-ca/.ca}"   # gitignored

mitm_up() {
  local runtime="$1"
  mkdir -p "$CA_DIR"
  "$runtime" rm -f "$MITM_NAME" >/dev/null 2>&1 || true
  "$runtime" run -d --name "$MITM_NAME" -p "${MITM_PORT}:8080" \
    -v "$(pwd)/${CA_DIR}:/home/mitmproxy/.mitmproxy" \
    "$MITM_IMAGE" mitmdump --mode regular --listen-port 8080 >/dev/null
  # wait for the CA to be generated
  for _ in $(seq 1 30); do
    [ -f "${CA_DIR}/mitmproxy-ca-cert.pem" ] && break; sleep 1
  done
  [ -f "${CA_DIR}/mitmproxy-ca-cert.pem" ] || { echo "mitm CA not generated"; return 1; }
  cp "${CA_DIR}/mitmproxy-ca-cert.pem" "${CA_DIR}/corp-ca.crt"
}
mitm_fingerprint() {
  openssl x509 -in "${CA_DIR}/corp-ca.crt" -noout -fingerprint -sha256 \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
}
mitm_down() { "${1:-docker}" rm -f "$MITM_NAME" >/dev/null 2>&1 || true; }
```

> Pin the digest first: `docker pull mitmproxy/mitmproxy && docker inspect --format='{{index .RepoDigests 0}}' mitmproxy/mitmproxy` → paste into `MITM_IMAGE`.

- [ ] **Step 2: Write the Node and Java probe helpers**

`images/proxy-ca-probe-ubi9/helpers/node-tls-probe.js` (dependency-free: HTTP CONNECT through the proxy, then a TLS handshake to the target validated against Node's trust store incl. `NODE_EXTRA_CA_CERTS`):

```js
'use strict';
const http = require('http');
const tls = require('tls');
const { URL } = require('url');

const target = new URL(process.env.TARGET_URL);
const proxyEnv = process.env.HTTPS_PROXY || process.env.https_proxy;
if (!proxyEnv) { console.error('no HTTPS_PROXY'); process.exit(4); }
const proxy = new URL(proxyEnv);
const port = target.port || 443;

const headers = {};
if (proxy.username) {
  const cred = `${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`;
  headers['Proxy-Authorization'] = 'Basic ' + Buffer.from(cred).toString('base64');
}
const req = http.request({
  host: proxy.hostname, port: proxy.port || 80, method: 'CONNECT',
  path: `${target.hostname}:${port}`, headers,
});
req.on('connect', (res, socket) => {
  if (res.statusCode !== 200) { console.error('CONNECT failed: ' + res.statusCode); process.exit(3); }
  const s = tls.connect({ socket, servername: target.hostname }, () => {
    if (s.authorized) { process.stdout.write('authorized'); s.end(); process.exit(0); }
    console.error('TLS not authorized: ' + s.authorizationError); process.exit(2);
  });
  s.on('error', (e) => { console.error('tls error: ' + e.message); process.exit(2); });
});
req.on('error', (e) => { console.error('connect error: ' + e.message); process.exit(3); });
req.end();
```

`images/proxy-ca-probe-ubi9/helpers/TlsProbe.java` (compiled to `TlsProbe.class` at image build and run as `java -cp <dir> TlsProbe`, so JRE-only target images with no `javac` can execute it; honors `JAVA_TOOL_OPTIONS` proxy/trustStore set by the platform):

```java
import java.net.*;
import java.io.*;

public class TlsProbe {
    public static void main(String[] args) throws Exception {
        String target = System.getenv("TARGET_URL");
        if (target == null) { System.err.println("no TARGET_URL"); System.exit(4); }
        // Proxy + trustStore come from JAVA_TOOL_OPTIONS (platform-set); see C-4.
        HttpURLConnection c = (HttpURLConnection) new URL(target).openConnection();
        c.setConnectTimeout(10000);
        c.setReadTimeout(10000);
        try (InputStream in = c.getInputStream()) {
            in.read();  // force the TLS handshake to complete
            System.out.println("status=" + c.getResponseCode());
            System.exit(0);
        } catch (javax.net.ssl.SSLException e) {
            System.err.println("ssl: " + e.getMessage());
            System.exit(2);
        }
    }
}
```

- [ ] **Step 3: Replace `run_live_checks` in `proxy-ca-probe.py`** with real checks

```python
import shutil, subprocess, ssl, urllib.request

HELPERS = os.environ.get(
    "PROBE_HELPERS_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "helpers"))


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30, **kw)


def _proxy():
    return os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")


def run_live_checks(checks):
    target = os.environ.get("TARGET_URL")
    expected_fp = os.environ.get("CORP_CA_FINGERPRINT", "")

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
    detail = "present" if bundle_ok else "MISSING — every TLS call will fail"
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
    pu = urllib.parse.urlparse(_proxy())
    hostport = f"{pu.hostname}:{pu.port or 8080}"

    # 4. openssl s_client through the proxy. `-proxy` takes a BARE host:port, so we
    #    parse host/port from the URL and route any credentials to -proxy_user/
    #    -proxy_pass instead of stripping them (else an authenticated corp proxy
    #    looks like a TLS-verify failure — a distinct failure mode).
    if shutil.which("openssl"):
        cmd = ["openssl", "s_client", "-connect", f"{host}:{port}",
               "-servername", host, "-proxy", hostport,
               "-verify_return_error", "-brief"]
        if pu.username:
            cmd += ["-proxy_user", urllib.parse.unquote(pu.username),
                    "-proxy_pass", urllib.parse.unquote(pu.password or "")]
        r = _run(cmd, input="")
        _verdict(checks, "openssl", "tls-via-proxy", r.returncode == 0,
                 r.stderr.strip()[-200:],
                 "openssl chain verify failed via proxy "
                 "(check proxy-auth vs CA-verify separately)")

    # 5. curl
    if shutil.which("curl"):
        r = _run(["curl", "-fsS", "-o", "/dev/null", "-w", "%{http_code}", target])
        _verdict(checks, "curl", "https-via-proxy", r.returncode == 0,
                 (r.stdout + r.stderr).strip()[-200:], "curl TLS verify failed (CURL_CA_BUNDLE / proxy)")

    # 6. python requests (or urllib if requests absent)
    _verdict(checks, "python", "https-via-proxy", *_python_https(target))

    # 7. node
    if shutil.which("node"):
        r = _run(["node", os.path.join(HELPERS, "node-tls-probe.js")])
        _verdict(checks, "node", "tls-via-proxy", r.returncode == 0,
                 (r.stdout + r.stderr).strip()[-200:], "Node TLS not authorized (NODE_EXTRA_CA_CERTS)")

    # 8. git — only when a REAL git endpoint is given. Defaulting to TARGET_URL
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

    # 9. java — the JVM is the documented EXCEPTION (C-4): it reads neither the PEM
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
    try:
        r = _run(["openssl", "crl2pkcs7", "-nocrl", "-certfile", path])
        r2 = _run(["openssl", "pkcs7", "-print_certs", "-noout"], input=r.stdout)
        # fall back: fingerprint each cert via -fingerprint on split certs
    except Exception:
        pass
    # Robust path: split bundle into individual certs and fingerprint each.
    try:
        data = open(path).read()
        for block in data.split("-----END CERTIFICATE-----"):
            if "BEGIN CERTIFICATE" not in block:
                continue
            pem = block + "-----END CERTIFICATE-----\n"
            r = _run(["openssl", "x509", "-noout", "-fingerprint", "-sha256"], input=pem)
            if r.returncode == 0:
                fps.add(r.stdout.split("=")[-1].strip().replace(":", "").lower())
    except Exception:
        pass
    return fps
```

> The python urlopen path relies on `urllib` reading `HTTPS_PROXY` from the environment, which it does via `getproxies()`. `requests` (installed in the image) honors `REQUESTS_CA_BUNDLE` + env proxy as well; either proves the python toolchain.

- [ ] **Step 4: Unit-gate the live check wiring (RED → GREEN)** with stubs

Add to `tests/test-proxy-ca-probe-report.sh` a `(d)` case that runs the probe with stubbed `curl`/`openssl`/`node`/`git`/`java` on `PATH` (each a script echoing success) and `TARGET_URL`/`HTTPS_PROXY` set to dummy values, asserting the JSON contains a `curl`/`python`/`node` check with the expected ids. Run it, watch the new case fail before Step 3's code is in place, then pass after.

Run: `bash tests/test-proxy-ca-probe-report.sh`
Expected: all cases PASS.

- [ ] **Step 5: Commit**

```bash
git add images/proxy-ca-probe-ubi9/proxy-ca-probe.py \
        images/proxy-ca-probe-ubi9/helpers tests/proxy-ca/lib/mitm.sh \
        tests/test-proxy-ca-probe-report.sh
git commit -m "feat(probe): live per-toolchain proxy+CA checks (openssl/curl/python/node/git/java)"
```

### Task A3: The probe Containerfile + image.yaml + README (TDD via policy)

**Files:**
- Create: `images/proxy-ca-probe-ubi9/Containerfile`, `image.yaml`, `README.md`, `smoke-cmd`

- [ ] **Step 1: Write the policy/build expectations as the failing gate**

Run (expected to fail until the files exist):
`bash tests/test-base-images-pinned.sh && pixi run policy-check-containerfiles && pixi run policy-check-image-meta`
Expected: errors about the missing/under-specified `proxy-ca-probe-ubi9` Containerfile + `image.yaml`.

- [ ] **Step 2: Write `images/proxy-ca-probe-ubi9/Containerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
# proxy-ca-probe-ubi9 — DIAGNOSTIC image for issue #59. Not a runtime product:
# it carries every TLS toolchain the catalog uses (openssl/curl/git/python/
# node/java) and reports, as filable bugs, whether each trusts the corporate
# inspection CA and egresses through the proxy. amd64 only.
FROM registry.access.redhat.com/ubi9/ubi:9.8@sha256:80b1f4c34a7eed1b03a05d12b55768f3e522eef6ec294c6fbd5fa47b6b2892ee

LABEL org.opencontainers.image.title="proxy-ca-probe-ubi9"
LABEL org.opencontainers.image.description="Diagnostic probe for the uniform proxy + CA-trust contract (issue #59)"
LABEL org.opencontainers.image.source="https://github.com/nq-rdl/container-images"
LABEL org.opencontainers.image.vendor="Research Data Laboratory"
LABEL org.opencontainers.image.licenses="MIT"

# Toolchains under test. java-17-openjdk-devel ships javac so we can PRECOMPILE the
# Java probe — JRE-only target images (e.g. zulu*-jre-headless) lack a compiler and
# cannot run `java TlsProbe.java` (single-file source launch needs jdk.compiler), so
# we ship a .class and run it with `java -cp`. nodejs:20 from the UBI appstream module.
RUN dnf -y module enable nodejs:20 \
 && dnf -y install --setopt=install_weak_deps=False \
      ca-certificates openssl curl-minimal git-core \
      python3 python3-pip python3-requests \
      nodejs java-17-openjdk-devel \
 && dnf clean all && rm -rf /var/cache/yum /var/cache/dnf

# The probe image is the REFERENCE implementation of the C-1 contract block.
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    CURL_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PIP_CERT=/etc/pki/tls/certs/ca-bundle.crt \
    GIT_SSL_CAINFO=/etc/pki/tls/certs/ca-bundle.crt \
    NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt

COPY proxy-ca-probe.py /usr/local/bin/proxy-ca-probe
COPY helpers/ /usr/local/lib/proxy-ca-probe/helpers/
ENV PROBE_HELPERS_DIR=/usr/local/lib/proxy-ca-probe/helpers
# Precompile the Java probe so JRE-only images (no javac) can run `java -cp … TlsProbe`.
RUN chmod +x /usr/local/bin/proxy-ca-probe \
 && javac /usr/local/lib/proxy-ca-probe/helpers/TlsProbe.java

# Run as the same hardened shape the catalog targets: non-root, GID 0.
RUN useradd -u 1001 -g 0 -m -s /sbin/nologin probe
USER 1001
WORKDIR /home/probe
ENTRYPOINT ["proxy-ca-probe"]
CMD ["--report", "human"]
```

> `proxy-ca-probe.py` references its helpers via `os.path.dirname(__file__)`. Since it is copied to `/usr/local/bin/proxy-ca-probe` and helpers to `/usr/local/lib/proxy-ca-probe/helpers/`, set `HELPERS` resolution to honor an env override: add near the top of the module `HELPERS = os.environ.get("PROBE_HELPERS_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "helpers"))` and bake `ENV PROBE_HELPERS_DIR=/usr/local/lib/proxy-ca-probe/helpers` into the Containerfile. (Update Task A2 Step 3 accordingly — keep the names identical.)

- [ ] **Step 3: Write `images/proxy-ca-probe-ubi9/image.yaml`**

```yaml
name: proxy-ca-probe-ubi9
description: Diagnostic probe for the uniform proxy + CA-trust contract (issue #59)
owners:
  - nq-rdl/platform
platforms:
  - linux/amd64
base:
  registry: registry.access.redhat.com
  repository: ubi9/ubi
  version: "9.8"
runtime:
  name: proxy-ca-probe
tags:
  - "0.1.0"
  - "0.1"
  - "latest"
support:
  status: experimental
  eol: "2027-06-30"
```

- [ ] **Step 4: Write `README.md` and `smoke-cmd`**

`smoke-cmd`:
```
--self-test
```

`README.md`: document `docker run -e TARGET_URL=https://example.com -e HTTPS_PROXY=http://proxy:8080 -e CORP_CA_FINGERPRINT=<sha256> ghcr.io/nq-rdl/proxy-ca-probe-ubi9:latest --report json`, the report schema (table of fields), the exit-code contract, and "each `fail` → open a bug with the `id`+`remediation`."

- [ ] **Step 5: Verify policy + base-pin + hadolint pass**

Run:
```bash
pixi run policy-check-containerfiles
pixi run policy-check-image-meta
bash tests/test-base-images-pinned.sh
pixi run lint-containerfiles
```
Expected: all PASS (image-meta tags `0.1.0`/`0.1`/`latest` valid; UBI base; 5 labels; vendor exact; base digest-pinned).

- [ ] **Step 6: Build + self-test the actual image**

```bash
docker build -t proxy-ca-probe-ubi9:dev images/proxy-ca-probe-ubi9
docker run --rm proxy-ca-probe-ubi9:dev --self-test --report human
```
Expected: a PASS line for `self-test`, exit 0.

- [ ] **Step 7: changie + commit**

```bash
changie new   # kind: Added — "proxy-ca-probe-ubi9 diagnostic image for issue #59"
git add images/proxy-ca-probe-ubi9 .changes/unreleased
git commit -m "feat(proxy-ca-probe): add amd64 UBI9 diagnostic image"
```

### Task A4: docker MITM acceptance of the probe (RED → GREEN)

**Files:**
- Create: `tests/proxy-ca/docker-compose.yaml`, `tests/proxy-ca/run-docker.sh`

- [ ] **Step 1: Write the failing acceptance test**

`tests/proxy-ca/run-docker.sh` (asserts: probe PASSES every toolchain when the MITM CA is folded in; and FAILS — detecting the MITM — when it is not):

```bash
#!/usr/bin/env bash
set -euo pipefail
[ -d images ] || { echo "ERROR: run from repo root"; exit 1; }
source tests/proxy-ca/lib/mitm.sh
RUNTIME="${RUNTIME:-docker}"
FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
trap 'mitm_down "$RUNTIME"' EXIT

mitm_up "$RUNTIME"
FP="$(mitm_fingerprint)"
docker build -t proxy-ca-probe-ubi9:dev images/proxy-ca-probe-ubi9

NET="proxy-ca-net-$$"; "$RUNTIME" network create "$NET" >/dev/null
"$RUNTIME" network connect "$NET" "$MITM_NAME"
common=(--rm --network "$NET"
  -e TARGET_URL=https://example.com
  -e HTTPS_PROXY="http://${MITM_NAME}:8080" -e https_proxy="http://${MITM_NAME}:8080"
  -e NO_PROXY=localhost,127.0.0.1 -e CORP_CA_FINGERPRINT="$FP")

# (a) WITHOUT the CA folded in → probe detects the MITM (non-zero exit, fail report)
if "$RUNTIME" run "${common[@]}" proxy-ca-probe-ubi9:dev --report json >/tmp/r_nocafold.json; then
  fail "(a) probe should FAIL when corp CA is not trusted"
else
  pass "(a) probe detects untrusted MITM CA"
fi

# (b) WITH the CA folded in (Tier-2: update-ca-trust regenerates BOTH the PEM bundle
#     and the system Java cacerts, which the probe image's JDK cacerts symlinks to),
#     every toolchain — including Java (PROBE_CHECK_JAVA=1) — must PASS.
"$RUNTIME" run "${common[@]}" -e PROBE_CHECK_JAVA=1 \
  -v "$(pwd)/${CA_DIR}/corp-ca.crt:/etc/pki/ca-trust/source/anchors/corp-ca.crt:ro" \
  --user 0 --entrypoint /bin/bash proxy-ca-probe-ubi9:dev \
  -c 'update-ca-trust extract && proxy-ca-probe --report json' >/tmp/r_cafold.json \
  && pass "(b) probe passes with CA folded in" || fail "(b) probe should pass with CA trusted"

python3 -c '
import json,sys
d=json.load(open("/tmp/r_cafold.json"))
assert d["summary"]["failed"]==0, d["summary"]
toolchains={c["toolchain"] for c in d["checks"] if c["category"]=="egress" and c["status"]=="pass"}
assert {"openssl","curl","python","node","git","java"} <= toolchains, toolchains
' && pass "(b2) all six toolchains verified through proxy" || fail "(b2) missing toolchain pass"

"$RUNTIME" network rm "$NET" >/dev/null 2>&1 || true
if [ "$FAILURES" -gt 0 ]; then echo "${FAILURES} docker MITM failure(s)"; exit 1; fi
echo "docker MITM acceptance OK"
```

- [ ] **Step 2: Run it; verify the *shape* of failure**

Run: `RUNTIME=docker bash tests/proxy-ca/run-docker.sh`
Expected at this stage: PASS on (a) (the probe correctly fails closed against an untrusted MITM) and PASS on (b)/(b2) once `update-ca-trust` folds the CA in. If (b) fails, the probe or contract is wrong — fix the probe, not the test.

- [ ] **Step 3: Commit**

```bash
git add tests/proxy-ca/run-docker.sh tests/proxy-ca/docker-compose.yaml
git commit -m "test(proxy-ca): docker MITM acceptance — probe fails closed / passes with CA folded in"
```

---

## Milestone B — Contract rollout across the 21 images

### Task B1: Coverage test — every buildable image bakes C-1 (RED first)

**Files:**
- Create: `tests/test-ca-env-vars.sh`
- Modify: `pyproject.toml`, `.github/workflows/policy.yml`

- [ ] **Step 1: Write the failing static test**

`tests/test-ca-env-vars.sh`:

```bash
#!/usr/bin/env bash
# Asserts every buildable image bakes the issue-#59 CA env contract (block C-1),
# OR inherits it from an in-repo chained base (ARG BASE_CONTAINER). Mirrors the
# fail()/pass() idiom of tests/test-base-images-pinned.sh.
set -euo pipefail
[ -d images ] || { echo "ERROR: run from the repo root"; exit 1; }

REQUIRED=(SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE \
          PIP_CERT GIT_SSL_CAINFO NODE_EXTRA_CA_CERTS)
BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

for cf in images/*/Containerfile; do
  dir="$(dirname "$cf")"; name="$(basename "$dir")"
  # chained images inherit the block from their in-repo base
  if grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf"; then
    pass "$name (inherits contract from chained base)"; continue
  fi
  missing=()
  for v in "${REQUIRED[@]}"; do
    grep -qE "(^|[[:space:]])ENV[[:space:]].*${v}=" "$cf" \
      || grep -qE "^[[:space:]]*${v}=" "$cf" || missing+=("$v")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "$name missing CA env: ${missing[*]}"; continue
  fi
  # every bundle-pointing var must EQUAL the always-present bundle (not merely exist)
  bad=()
  for v in SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE PIP_CERT GIT_SSL_CAINFO; do
    grep -qE "${v}=${BUNDLE//\//\\/}" "$cf" || bad+=("$v")
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    fail "$name vars not pinned to ${BUNDLE}: ${bad[*]} (invariant C-2)"; continue
  fi
  pass "$name bakes the CA env contract"
done

# node-ubi9 is an empty stub (no Containerfile) — nothing to assert; documented.
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} image(s) missing the CA env contract"; exit 1
fi
echo "All buildable images bake the CA env contract"; exit 0
```

> **Static grep is a fast CI pre-filter, not the authoritative gate** (adversarial-review finding). It certifies any `ARG BASE_CONTAINER` image by *assuming* its base carries the block, and it cannot detect a stale published base digest that fails to actually provide the env. The authoritative gate is the **built-image env assertion in Task C3 Step 1b**, which `docker inspect`s every *built* image (chained inheritance resolved naturally) for the exact contract values and verifies invariant C-2 at runtime. Keep both: the static test gates CI cheaply; the built-image test gates the rollout's completion.

- [ ] **Step 2: Run it; verify it fails for all 17 non-chained images**

Run: `bash tests/test-ca-env-vars.sh`
Expected: `FAIL: <name> missing CA env: ...` for every non-chained image (chained datascience/jamovi children pass via inheritance once their bases are done — but the bases themselves fail until B2/B4). Net: red.

- [ ] **Step 3: Wire into pixi + CI (so it gates from now on)**

`pyproject.toml`: add `policy-check-ca-env = "bash tests/test-ca-env-vars.sh"` and append `policy-check-ca-env` to the `policy-check` aggregate `depends-on`.
`.github/workflows/policy.yml`: add after the existing workflow-tags step:
```yaml
      - name: Validate CA env contract is baked into every image
        run: bash tests/test-ca-env-vars.sh
```

- [ ] **Step 4: Commit the red test (it gates the rest of Milestone B)**

```bash
git add tests/test-ca-env-vars.sh pyproject.toml .github/workflows/policy.yml
git commit -m "test(ca-env): coverage test — every image must bake the CA env contract (red)"
```

### Task B2: Leaf images — bake C-1 (GREEN, one worked example + per-image table)

**Files (modify, add the C-1 block before the final `USER`):**
- `images/python-ubi9/Containerfile`
- `images/bun-ubi9/Containerfile`
- `images/dbt-ubi9/Containerfile` (see Task B5 for the `ubi-micro` bundle staging)
- `images/r-base-ubi9/Containerfile`
- `images/jamovi-ubi9/Containerfile` (runs as root; block goes before `CMD`)

> Java leaves (`zulu*`) are handled in Task B6 (they need keystore wiring too).

- [ ] **Step 1: Worked example — `images/python-ubi9/Containerfile`**

Insert the C-1 block immediately before the existing `USER 1001` line:

```dockerfile
# ... existing ENV (LANG, PYTHONUNBUFFERED, ...) ...

# --- issue #59: uniform CA-trust env contract (see docs/proxy-and-ca.md) ---
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    CURL_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PIP_CERT=/etc/pki/tls/certs/ca-bundle.crt \
    GIT_SSL_CAINFO=/etc/pki/tls/certs/ca-bundle.crt \
    NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt

USER 1001
ENTRYPOINT ["python3"]
```

- [ ] **Step 2: Verify the bundle exists in `python-ubi9`** (invariant C-2)

```bash
docker build -t python-ubi9:dev images/python-ubi9
docker run --rm --entrypoint /bin/sh python-ubi9:dev -c \
  'test -s /etc/pki/tls/certs/ca-bundle.crt && echo BUNDLE_OK'
```
Expected: `BUNDLE_OK`. (If absent, add `microdnf install -y ca-certificates` in a root RUN — `ubi-minimal` ships it, so this should pass.)

- [ ] **Step 3: Apply the identical block to the other leaves**

| Image | Insert the C-1 block… | Bundle check command |
|---|---|---|
| `bun-ubi9` | before `USER 1001` | `docker run --rm --entrypoint /bin/sh bun-ubi9:dev -c 'test -s /etc/pki/tls/certs/ca-bundle.crt'` |
| `r-base-ubi9` | before the final `USER`/`CMD` | same |
| `jamovi-ubi9` | before the final `CMD` (runs as root) | same |
| `dbt-ubi9` | before `USER 1001` **and** see Task B5 | see Task B5 |

The block is byte-for-byte identical to Step 1 (do not vary it — the coverage test greps for exact values).

- [ ] **Step 4: Run the coverage test; the five leaves go green**

Run: `bash tests/test-ca-env-vars.sh`
Expected: `PASS: python-ubi9 …`, `PASS: bun-ubi9 …`, `PASS: r-base-ubi9 …`, `PASS: jamovi-ubi9 …` (dbt may still fail until B5). Java leaves still fail until B6.

- [ ] **Step 5: changie + commit**

```bash
changie new   # Added — "bake uniform CA-trust env contract into leaf images"
git add images/python-ubi9 images/bun-ubi9 images/r-base-ubi9 images/jamovi-ubi9 .changes/unreleased
git commit -m "feat(ca-env): bake CA-trust env contract into python/bun/r-base/jamovi"
```

### Task B3: Bun & Node-toolchain note (NODE_EXTRA_CA_CERTS reality check)

**Files:** `images/bun-ubi9/Containerfile` (already edited in B2)

- [ ] **Step 1: Verify bun honors `NODE_EXTRA_CA_CERTS`** with a folded CA

```bash
# reuse the MITM fixture from Task A2
source tests/proxy-ca/lib/mitm.sh; mitm_up docker; FP=$(mitm_fingerprint)
docker run --rm --network "$(docker network ls --filter name=proxy-ca --format '{{.Name}}' | head -1)" \
  -e HTTPS_PROXY=http://proxy-ca-mitm:8080 \
  -v "$(pwd)/tests/proxy-ca/.ca/corp-ca.crt:/etc/pki/ca-trust/source/anchors/corp-ca.crt:ro" \
  --user 0 --entrypoint /bin/sh bun-ubi9:dev -c \
  'update-ca-trust extract && bun -e "await fetch(\"https://example.com\")" && echo BUN_TLS_OK'
mitm_down docker
```
Expected: `BUN_TLS_OK`. If bun ignores the system bundle and only honors `NODE_EXTRA_CA_CERTS`, the baked `NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt` already covers the Tier-2/anchor-mount path; document the finding in `docs/proxy-and-ca.md`.

- [ ] **Step 2: Commit any doc note** (no code change if it passed)

### Task B4: Notebook chain — bake C-1 in the base, add Tier-2 root hook

**Files:**
- Modify: `images/docker-stacks-foundation-ubi9/Containerfile` (the chain root — C-1 here is inherited by base/minimal/scipy)
- Create: `images/docker-stacks-foundation-ubi9/before-notebook.d/10-update-ca-trust.sh`
- Modify: `images/docker-stacks-foundation-ubi9/Containerfile` to `COPY` the hook + `chmod +x`

- [ ] **Step 1: Add the C-1 block to the foundation Containerfile**

Insert the C-1 block (identical to B2 Step 1) in a `USER root` section before the final `USER 1000`. Because `base-notebook`, `minimal-notebook`, `scipy-notebook` all `FROM ${BASE_CONTAINER}` the foundation, they inherit it — the coverage test passes them via the `ARG BASE_CONTAINER` branch.

- [ ] **Step 2: Write the Tier-2 root hook (RED: prove it folds the CA only when asked)**

`images/docker-stacks-foundation-ubi9/before-notebook.d/10-update-ca-trust.sh`:

```bash
#!/bin/bash
# issue #59 Tier-2: when CA_BUNDLE=1 and a raw corp anchor is mounted, fold it
# into the consolidated bundle (and the Java cacerts) at startup. This hook runs
# as ROOT in the docker-stacks start.sh root branch, BEFORE the drop to NB_USER.
# No-op unless explicitly enabled, so default users see zero behavior change.
set -euo pipefail
[ "${CA_BUNDLE:-0}" = "1" ] || exit 0
anchor=/etc/pki/ca-trust/source/anchors/corp-ca.crt
if [ ! -s "$anchor" ]; then
  echo "[ca-trust] CA_BUNDLE=1 but $anchor is absent; skipping" >&2
  exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "[ca-trust] CA_BUNDLE=1 but not root (arbitrary-UID launch); cannot update-ca-trust." >&2
  echo "[ca-trust] Use Tier-1 (mount a complete bundle) on non-root pods." >&2
  exit 0
fi
update-ca-trust extract
echo "[ca-trust] folded $anchor into the system bundle"
```

- [ ] **Step 3: COPY the hook into the image**

In `images/docker-stacks-foundation-ubi9/Containerfile`, in a `USER root` block:
```dockerfile
COPY before-notebook.d/10-update-ca-trust.sh /usr/local/bin/before-notebook.d/10-update-ca-trust.sh
RUN chmod +x /usr/local/bin/before-notebook.d/10-update-ca-trust.sh
```

- [ ] **Step 4: Verify build + coverage + shellcheck**

```bash
pixi run lint-shell            # hook must pass shellcheck (scripts/ + tests/; images/ excluded from pre-commit but lint-shell covers tests/scripts only — run shellcheck on the hook explicitly)
shellcheck images/docker-stacks-foundation-ubi9/before-notebook.d/10-update-ca-trust.sh
bash tests/test-ca-env-vars.sh # foundation + 3 notebook children now pass
docker buildx bake --file docker-bake.hcl foundation --load
```
Expected: shellcheck clean; coverage test passes foundation/base/minimal/scipy.

- [ ] **Step 5: changie + commit**

```bash
changie new   # Added — "CA env contract + Tier-2 update-ca-trust hook for the notebook chain"
git add images/docker-stacks-foundation-ubi9 .changes/unreleased
git commit -m "feat(ca-env): notebook chain bakes contract + CA_BUNDLE=1 Tier-2 hook"
```

### Task B5: `dbt-ubi9` ubi-micro — guarantee the bundle exists

**Files:** `images/dbt-ubi9/Containerfile`

- [ ] **Step 1: RED — prove the final image lacks/has the bundle**

```bash
docker build -t dbt-ubi9:dev images/dbt-ubi9
docker run --rm --entrypoint /bin/sh dbt-ubi9:dev -c \
  'test -s /etc/pki/tls/certs/ca-bundle.crt && echo OK || echo MISSING'
```
Expected: if `MISSING`, the contract is broken (every TLS call fails). Proceed to Step 2. If `OK`, only the C-1 block (B2) is needed.

- [ ] **Step 2: Stage the consolidated bundle from the rootfs stage** (only if MISSING)

In the `runtime-rootfs` (`ubi:9.5`) stage, ensure `ca-certificates` is installed and the extracted PEM exists, then in the final `ubi-micro` stage copy it in:
```dockerfile
# runtime-rootfs stage (ubi:9.5):
RUN dnf -y install ca-certificates && update-ca-trust extract \
 && dnf clean all
# ... existing rootfs assembly ...

# final ubi-micro stage:
COPY --from=runtime-rootfs /etc/pki/ca-trust/extracted/pem /etc/pki/ca-trust/extracted/pem
COPY --from=runtime-rootfs /etc/pki/tls/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt
```
Then add the C-1 block before `USER 1001`.

- [ ] **Step 3: Verify bundle + coverage + a python TLS smoke**

```bash
docker build -t dbt-ubi9:dev images/dbt-ubi9
docker run --rm --entrypoint /bin/sh dbt-ubi9:dev -c \
  'test -s /etc/pki/tls/certs/ca-bundle.crt && python3 -c "import ssl; ssl.create_default_context()" && echo OK'
bash tests/test-ca-env-vars.sh   # dbt-ubi9 now passes
```
Expected: `OK`; dbt-ubi9 green.

- [ ] **Step 4: changie + commit**

```bash
changie new   # Fixed — "dbt-ubi9 ubi-micro: guarantee the system CA bundle is present"
git add images/dbt-ubi9 .changes/unreleased
git commit -m "fix(dbt): stage system CA bundle into ubi-micro + bake CA env contract"
```

### Task B6: Java images — system-trust wiring + bake C-1 (the JVM exception)

**Files (10 Java images):** `zulu17-jdk-ubi9`, `zulu17-jre-headless-ubi9`, `zulu21-jdk-ubi9`, `zulu21-jre-headless-ubi9`, `pyspark-ubi9`, `spark-ubi9`, `starrocks-allin1-ubi9`, `starrocks-be-ubi9`, `starrocks-cn-ubi9`, `starrocks-fe-ubi9`.

> Decision (resolves Open Question #1): make the JDK keystore resolve to the **system-extracted** Java cacerts so that build-time / Tier-2 `update-ca-trust` reaches Java. Leaf Tier-1 (zulu) additionally documents the platform-set `JAVA_TOOL_OPTIONS` keystore path (C-4) — not baked.

- [ ] **Step 1: Worked example — `images/zulu21-jre-headless-ubi9/Containerfile`**

In a root RUN before `USER 1001`, install `ca-certificates`, extract, and point the JDK keystore at the system one:
```dockerfile
RUN microdnf install -y ca-certificates \
 && update-ca-trust extract \
 && ln -sf /etc/pki/ca-trust/extracted/java/cacerts \
           "${JAVA_HOME}/lib/security/cacerts" \
 && microdnf clean all && rm -rf /var/cache/yum /var/cache/dnf
```
Then add the C-1 block before `USER 1001`.

- [ ] **Step 2: RED → GREEN — prove a folded CA reaches Java**

```bash
docker build -t zulu21-jre:dev images/zulu21-jre-headless-ubi9
source tests/proxy-ca/lib/mitm.sh; mitm_up docker
docker run --rm \
  -v "$(pwd)/tests/proxy-ca/.ca/corp-ca.crt:/etc/pki/ca-trust/source/anchors/corp-ca.crt:ro" \
  --user 0 --entrypoint /bin/bash zulu21-jre:dev -c '
    update-ca-trust extract
    keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit \
      | grep -qi mitmproxy && echo JAVA_TRUSTS_CORP_CA'
mitm_down docker
```
Expected: `JAVA_TRUSTS_CORP_CA` (the symlinked keystore now contains the folded CA).

- [ ] **Step 3: Apply per-image** (placement differs by family)

| Image | Install ca-certificates + symlink cacerts… | Notes |
|---|---|---|
| `zulu17-jdk-ubi9`, `zulu17-jre-headless-ubi9`, `zulu21-jdk-ubi9` | root RUN before `USER 1001`; `JAVA_HOME` already set | identical to Step 1 with the right `JAVA_HOME` |
| `pyspark-ubi9`, `spark-ubi9` | root RUN before `USER spark`; `JAVA_HOME=/usr/lib/jvm/jre-17-openjdk` (OpenJDK already symlinks cacerts to the system store — verify; if so, only `ca-certificates`+`update-ca-trust` needed) | OpenJDK headless usually links cacerts to `/etc/pki/ca-trust/extracted/java/cacerts` already |
| `starrocks-allin1/be/cn/fe-ubi9` | root RUN (image runs as root); `JAVA_HOME=/usr/lib/jvm/java-17` | `ca-certificates` already installed on allin1/be — verify symlink |

For each: add the C-1 block before the final `USER`/`ENTRYPOINT`.

- [ ] **Step 4: Coverage + per-image Java verify**

Run `bash tests/test-ca-env-vars.sh` → all 10 Java images green. For OpenJDK images confirm `readlink -f "$JAVA_HOME/lib/security/cacerts"` resolves under `/etc/pki/ca-trust/extracted/java`.

- [ ] **Step 5: changie + commit**

```bash
changie new   # Added — "Java images: system-trust cacerts wiring + CA env contract (issue #59 JVM exception)"
git add images/zulu* images/pyspark-ubi9 images/spark-ubi9 images/starrocks-* .changes/unreleased
git commit -m "feat(ca-env): Java images wire JDK cacerts to system trust + bake contract"
```

### Task B7: Bespoke root entrypoints — optional Tier-2 hook

**Files:** `images/starrocks-allin1-ubi9/entrypoint.sh`, `images/starrocks-be-ubi9/be_entrypoint.sh` (root, have a startup script)

- [ ] **Step 1: Add a guarded fold-in at the top of each root entrypoint**

Insert before the existing `exec`/`supervisord` line:
```bash
# issue #59 Tier-2: fold a mounted corp CA into system + Java trust when asked.
if [ "${CA_BUNDLE:-0}" = "1" ] && [ -s /etc/pki/ca-trust/source/anchors/corp-ca.crt ] && [ "$(id -u)" -eq 0 ]; then
  update-ca-trust extract || echo "[ca-trust] update-ca-trust failed" >&2
fi
```
`pyspark`/`spark`/`spark-operator` run **non-root** with no root hook → **no** Tier-2; they rely on Tier-1 (build-time symlink from B6 makes a mounted-then-extracted bundle reach Java, but extraction needs root, so on non-root pods use Tier-1 keystore mount + `JAVA_TOOL_OPTIONS`). Document this split in `docs/proxy-and-ca.md`.

- [ ] **Step 2: shellcheck + commit**

```bash
shellcheck images/starrocks-allin1-ubi9/entrypoint.sh images/starrocks-be-ubi9/be_entrypoint.sh
changie new   # Added — "Tier-2 CA_BUNDLE hook in starrocks root entrypoints"
git add images/starrocks-allin1-ubi9 images/starrocks-be-ubi9 .changes/unreleased
git commit -m "feat(ca-env): optional CA_BUNDLE=1 Tier-2 fold-in for starrocks root entrypoints"
```

### Task B8: Optional `/etc/profile.d/proxy.sh` for interactive shells

**Files:** notebook + starrocks images (those with a shell). Skip leaf images.

- [ ] **Step 1:** Add a small `profile.d` script (re-exports both-case proxy vars) only where an interactive shell is plausible (`kubectl exec`, notebook terminal). One-line task; low priority; document it as convenience-only in `docs/proxy-and-ca.md`. Commit with a changie `Added` fragment.

---

## Milestone C — Runtime acceptance on docker + k3d

### Task C1: k3d Tier-1 — non-root, read-only-rootfs, mounted bundle (RED → GREEN)

**Files:** `tests/proxy-ca/k3d/00-namespace.yaml`, `10-proxy.yaml`, `20-ca-configmap.yaml`, `30-probe-job.yaml`, `tests/proxy-ca/run-k3d.sh`

- [ ] **Step 1: Write the k3d manifests** (CA mounted as a **whole directory** at a stable path — never `subPath`)

`20-ca-configmap.yaml` carries the complete bundle (public roots + corp CA) generated by `run-k3d.sh`, **stored under the key `tls-ca-bundle.pem`** (or projected with `items[].path: tls-ca-bundle.pem`). `30-probe-job.yaml` runs the probe with `securityContext: {runAsNonRoot: true, runAsUser: 1001, readOnlyRootFilesystem: true}`, `HTTPS_PROXY` pointing at the in-cluster proxy Service, and the ConfigMap projected as a **whole directory** over `/etc/pki/ca-trust/extracted/pem/` (directory mount → live-updates) so the baked `/etc/pki/tls/certs/ca-bundle.crt` symlink resolves to the mounted `tls-ca-bundle.pem`, plus the raw anchor at `NODE_EXTRA_CA_CERTS`. The probe's first check asserts `test -s "$(readlink -f /etc/pki/tls/certs/ca-bundle.crt)"` inside the pod (catches a wrong ConfigMap key — the dangling-symlink trap).

> **Java is SKIP under PEM-only Tier-1** (the JVM can't read a PEM bundle — C-4): the Job leaves `PROBE_CHECK_JAVA` unset, so the `java` egress check reports `skip` and `summary.failed == 0` holds. Java trust + proxy are validated separately in Task C5 with a mounted keystore + `JAVA_TOOL_OPTIONS`.

- [ ] **Step 2: Write `tests/proxy-ca/run-k3d.sh`** (RED first)

It must: create a k3d cluster (`k3d cluster create proxy-ca-$$`), build + `k3d image import` the proxy + probe images, generate the complete bundle ConfigMap (`cat ubi-ca-bundle + corp-ca.crt`), `kubectl apply` the manifests, `kubectl wait --for=condition=complete job/proxy-ca-probe`, then assert the probe Job's logs report `summary.failed == 0` and that it ran **non-root + read-only**. Tear down via `trap`.

```bash
# assertion core
kubectl -n proxy-ca wait --for=condition=complete --timeout=180s job/proxy-ca-probe
kubectl -n proxy-ca logs job/proxy-ca-probe | tee /tmp/k3d-probe.json
python3 -c 'import json;d=json.load(open("/tmp/k3d-probe.json"));assert d["summary"]["failed"]==0,d["summary"]'
```

- [ ] **Step 3: Run it; iterate to green**

Run: `bash tests/proxy-ca/run-k3d.sh`
Expected: Job completes; `summary.failed == 0`; pod ran as 1001 with read-only rootfs. If the probe needs a writable dir (it shouldn't — it writes nothing), that's a finding to fix in the probe, not a relaxation of the securityContext.

- [ ] **Step 4: Commit**

```bash
git add tests/proxy-ca/k3d tests/proxy-ca/run-k3d.sh
git commit -m "test(proxy-ca): k3d Tier-1 acceptance — non-root, read-only rootfs, dir-mounted bundle"
```

### Task C2: k3d CA rotation (the subPath trap)

**Files:** `tests/proxy-ca/run-k3d.sh` (extend), `tests/proxy-ca/k3d/30-probe-job.yaml` (checksum annotation)

- [ ] **Step 1: RED — assert a rotated CA takes effect on a long-running pod**

Extend `run-k3d.sh`: deploy the probe as a `Deployment` (not Job) that re-probes on a loop; rotate the ConfigMap to a *second* MITM CA; assert that within the kubelet sync period the directory mount updates and the new CA is trusted (prove directory mounts live-update), **and** that a `checksum/ca` pod annotation change triggers a rollout. Assert the negative control: a `subPath` single-file mount does **not** update (documents why we forbid it).

- [ ] **Step 2: GREEN + commit**

```bash
git commit -am "test(proxy-ca): k3d CA rotation — directory mount live-updates; subPath does not"
```

### Task C3: Wire catalog images into the MITM acceptance (docker + k3d)

**Files:** `tests/proxy-ca/run-docker.sh` (extend), `scripts/proxy-ca-test.sh`, `pyproject.toml`, `.pre-commit-config.yaml`

- [ ] **Step 1: Extend `run-docker.sh`** to run a representative slice — `python-ubi9`, `zulu21-jre-headless-ubi9`, `base-notebook-ubi9` (Tier-2 root hook), `dbt-ubi9` (ubi-micro) — behind the MITM proxy with the CA folded in, asserting a TLS call succeeds in each. Python: `python3 -c 'import urllib.request,os; urllib.request.urlopen(os.environ["TARGET_URL"])'`. Zulu (JRE, no `javac`): mount the **precompiled** `TlsProbe.class` from the probe image and run `java -cp /probe TlsProbe` with `PROBE_CHECK_JAVA`/`JAVA_TOOL_OPTIONS` set, or assert trust directly via `keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit | grep -qi mitmproxy`. Notebook: start with `CA_BUNDLE=1` + anchor mount and assert the root hook folds it.

- [ ] **Step 1b: Authoritative built-image env assertion (covers chained inheritance + stale bases)**

Add `tests/test-ca-env-built.sh` (runs in the build-bearing layer, reusing smoke-test's built tags incl. bake `:latest`). This is the gate the static grep cannot be:

```bash
for tag in "${TAGS[@]}"; do            # every built catalog tag, chained included
  env_json="$(docker inspect -f '{{json .Config.Env}}' "$tag")"
  for kv in \
    SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    CURL_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    PIP_CERT=/etc/pki/tls/certs/ca-bundle.crt \
    GIT_SSL_CAINFO=/etc/pki/tls/certs/ca-bundle.crt \
    NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/source/anchors/corp-ca.crt; do
    echo "$env_json" | grep -q "\"$kv\"" || fail "$tag missing env $kv"
  done
  # invariant C-2: the always-present bundle must resolve, non-empty, inside the image
  docker run --rm --entrypoint /bin/sh "$tag" -c \
    'test -s "$(readlink -f /etc/pki/tls/certs/ca-bundle.crt)"' \
    || fail "$tag: /etc/pki/tls/certs/ca-bundle.crt missing/empty"
done
```

Wire it into `scripts/proxy-ca-test.sh`; document that **this**, not the static grep, is the rollout's completion gate.

- [ ] **Step 2: `scripts/proxy-ca-test.sh`** orchestrates `run-docker.sh` then `run-k3d.sh` (and `test-ca-env-built.sh`); add pixi task `proxy-ca-test`; add an **opt-in** pre-push hook behind `SKIP_PROXY_CA=1` (default-skip to keep push fast; document in CONTRIBUTING).

- [ ] **Step 3: Commit**

```bash
git add scripts/proxy-ca-test.sh tests/proxy-ca/run-docker.sh pyproject.toml .pre-commit-config.yaml
git commit -m "test(proxy-ca): catalog-image MITM acceptance on docker + k3d (opt-in)"
```

### Task C4: Tier-3 openssl-fetch fallback (opt-in, dev only)

**Files:** a small `tier3-fetch-ca.sh` referenced by the Tier-2 hooks when `CA_BUNDLE=1` and no anchor is mounted.

- [ ] **Step 1: TDD the URL parsing** (the credentialed-proxy trap)

Write `tests/test-tier3-proxy-parse.sh` asserting `http://user:pass@proxy:8080` → host `proxy`, port `8080`, user/pass routed to `-proxy_user`/`-proxy_pass`, and `http://proxy:8080` → bare `proxy:8080`. RED, then implement the parser in `tier3-fetch-ca.sh`, GREEN.

- [ ] **Step 2:** Gate it behind explicit opt-in; document TOFU + crashloop caveats in `docs/proxy-and-ca.md`. Commit.

### Task C5: Java acceptance — Zulu + Spark smoke (acceptance-criteria gate)

**Files:** `tests/proxy-ca/run-docker.sh` (Java cases)

- [ ] **Step 1: RED → GREEN** — for `zulu21-jre-headless-ubi9` and `spark-ubi9`, assert: (a) TLS to the MITM-CA endpoint succeeds with the folded keystore (proves trust); (b) with `JAVA_TOOL_OPTIONS=-Dhttps.proxyHost=… -Dhttps.proxyPort=…` egress goes through the proxy (assert the proxy log shows the CONNECT). Only when both pass is the "uniform" wording accepted for Java.

- [ ] **Step 2: Commit.**

---

## Milestone D — Documentation

### Task D1: `docs/proxy-and-ca.md`

- [ ] **Step 1:** Write the doc: the C-1 contract table; the three tiers with a decision (Tier-1 directory-mount is the standard; subPath forbidden); per-runtime example manifests (docker `-e`+`-v`, podman, k3s/RKE2 ConfigMap→projected dir, OpenShift `inject-trusted-cabundle`); `NO_PROXY` defaults + both-case proxy vars + why not `/etc/environment`/`profile`; the JVM exception (keystore + `JAVA_TOOL_OPTIONS`, platform-set); `CA_BUNDLE=1` semantics; the rotation guidance (directory mount and/or checksum rollout); link the probe image as the verification tool. Resolve the four Open Questions inline.

- [ ] **Step 2:** Update `CONTRIBUTING.md` to reference the contract + note the stale dependabot step. changie + commit.

---

## Milestone E — Corp-env validation loop (un-WIP gate)

### Task E1: Publish the probe + run on corp

- [ ] **Step 1:** Merge Milestone A so `proxy-ca-probe-ubi9` publishes to GHCR (amd64).
- [ ] **Step 2:** On the corp env, run the probe against a real internal HTTPS target through the real proxy with the real corp CA mounted:
  ```bash
  docker run --rm -e TARGET_URL=https://<internal-host> \
    -e HTTPS_PROXY=$HTTPS_PROXY -e NO_PROXY=$NO_PROXY \
    -e CORP_CA_FINGERPRINT=<sha256-of-corp-ca> \
    -v /path/to/corp-ca.crt:/etc/pki/ca-trust/source/anchors/corp-ca.crt:ro \
    --user 0 --entrypoint /bin/bash ghcr.io/nq-rdl/proxy-ca-probe-ubi9:latest \
    -c 'update-ca-trust extract && proxy-ca-probe --report json' > corp-report.json
  ```
  Repeat under k8s (RKE2/OpenShift) with a Tier-1 ConfigMap mount on a non-root, read-only pod.
- [ ] **Step 3:** For each `fail` in `corp-report.json`, open a GitHub issue titled `proxy-ca: <toolchain> <id>` with the `expected`/`actual`/`remediation` fields. Link them to #59.
- [ ] **Step 4:** When the corp report is all-pass across docker + RKE2 + OpenShift (and Java via Zulu+Spark), flip the PR out of draft and check the issue's acceptance boxes.

---

## Open decisions (raise with the user before/while executing)

1. **Legacy GHCR packages.** 19 non-`-ubi9` packages (`python`, `bun`, `spark`, …) are not built from this repo. The contract can't be applied to them (no source). Options: (a) leave as-is; (b) `scripts/ghcr-purge.sh` them; (c) confirm they're deprecated aliases. **Recommend (c) then (b).**
2. **Probe image publication.** Publish `proxy-ca-probe-ubi9` to GHCR (needed to pull on corp) vs keep local-only. **Recommend publish** (`support.status: experimental`), since corp needs to pull it.
3. **`proxy-ca-test` in CI.** There is no image-building CI lane today (smoke/trivy are pre-push only). Add a dedicated CI job (kind/k3d in Actions) or keep it local-only + corp-manual. **Recommend local-only now**, revisit after E.
4. **Bake order vs base-drift.** Editing every Containerfile will race `base-drift.yml` digest-bump PRs. Sequence: land B per-family in small PRs to minimize conflicts.

---

## Self-review (against issue #59 acceptance criteria)

- [x] Single documented CA-trust + proxy-env contract identical across runtimes → C-1..C-5 + D1.
- [x] No corp cert committed/baked → only `tests/proxy-ca/.ca/` (gitignored) + runtime mounts; nothing in images.
- [x] Ecosystem CA env vars baked at the always-present bundle → B1 coverage test enforces it on all 21.
- [x] Tier-1 verified non-root + read-only rootfs, no startup cost, no leaf entrypoint change → C1.
- [x] CA rotation handled (directory mount / checksum rollout; subPath forbidden) → C2 + D1.
- [x] JVM contract verified with Zulu + Spark → B6 + C5.
- [x] Tier-2 verified on entrypoint-bearing root image → B4 + B7.
- [x] Tier-3 opt-in dev fallback with caveats → C4 + D1.
- [x] Proxy env documented (both cases, NO_PROXY, why not /etc/environment; optional profile.d) → B8 + D1.
- [x] README/CONTRIBUTING/docs document the contract + example manifests → D1.
- [x] CI smoke test asserting TLS verification on a non-root/read-only pod per toolchain (Open Question #4 → **yes**) → C1 + the optional CI lane in Open Decision #3.
- **Probe image (user ask):** amd64-only diagnostic that runs the checks and reports filable bugs → Milestone A + E.
- **"Manage the 38 packages":** all 21 source images get the contract (coverage-test-enforced); legacy 19 packages → Open Decision #1.

---

## Revision log — codex adversarial review (2026-06-14)

Ran `/codex:adversarial-review` against this plan (verdict: *needs-attention*). All six findings were verified as technically sound and folded in:

| # | Sev | Finding | Resolution in this plan |
|---|---|---|---|
| 1 | high | Tier-1 dir mount can dangle the `ca-bundle.crt` symlink if the ConfigMap key ≠ `tls-ca-bundle.pem` | C-3 Tier-1 now mandates key/`items[].path: tls-ca-bundle.pem`; every Tier-1 test asserts `readlink -f /etc/pki/tls/certs/ca-bundle.crt` resolves non-empty (C1 Step 1). |
| 2 | high | Tier-1 k3d expected `failed==0` but PEM-only Tier-1 can't satisfy Java | Probe gates Java on explicit `PROBE_CHECK_JAVA`; C1 leaves it unset → Java `skip`; Java asserted with keystore+`JAVA_TOOL_OPTIONS` in C5. |
| 3 | high | `java TlsProbe.java` needs a compiler JRE-only images lack | Probe builds with `java-17-openjdk-devel`, **precompiles** `TlsProbe.class`, runs `java -cp … TlsProbe`; catalog Java checks use the precompiled class. |
| 4 | high | Grep coverage test can certify chained images / stale bases without the env | Static test hardened to assert *every* bundle-pointing var's exact value; **authoritative** built-image `docker inspect` gate added (C3 Step 1b) covering chained inheritance + invariant C-2. |
| 5 | med | `SSL_CERT_DIR=/etc/pki/tls/certs` is a no-op/footgun (not a c_rehash dir) | **Dropped `SSL_CERT_DIR`** from the baked contract; `SSL_CERT_FILE` is authoritative and always-present (documented deviation from the issue's table). |
| 6 | med | Probe `git` defaults to a non-git URL; `openssl` strips proxy creds → false bugs | `git` check `skip`s unless `TARGET_GIT_URL` is a real endpoint; `openssl` parses host/port and routes creds to `-proxy_user`/`-proxy_pass`, distinguishing proxy-auth from CA-verify failures. |

These changes make the probe fail/skip for *contract* reasons only, and make the rollout's completion gate a built-image assertion rather than a source grep.
