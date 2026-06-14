# proxy-ca-probe-ubi9

amd64 diagnostic image for the issue #59 **uniform proxy + CA-trust contract**.
It carries every TLS toolchain the catalog uses (openssl, curl, git, Python,
Node, Java) and reports, per toolchain, whether each trusts the corporate
inspection CA and egresses through the proxy.

This image is the reference implementation of the baked CA-env contract and is
the field instrument for corp-env validation (issue #59). Each `fail` in the
report is a filable bug: use the check's `id` to title it and the `remediation`
field for the suggested fix.

## Usage

Offline self-test (no network; exercises the report machinery):

```bash
docker run --rm ghcr.io/nq-rdl/proxy-ca-probe-ubi9:latest --self-test --report human
```

Live per-toolchain checks through a corporate proxy:

```bash
docker run --rm \
  -e TARGET_URL=https://example.com \
  -e HTTPS_PROXY=http://proxy:8080 \
  -e CORP_CA_FINGERPRINT=<sha256> \
  ghcr.io/nq-rdl/proxy-ca-probe-ubi9:latest --report json
```

## Flags

- `--self-test` — run offline; exercise the report machinery (CI / hermetic).
- `--report json|human` — output format. Default is `json` for the bare probe;
  the image's default `CMD` is `--report human`.

Default (no `--self-test`) runs live checks against `TARGET_URL` through
`HTTPS_PROXY`. If either is unset, only the offline env/bundle contract checks
run and the egress checks are skipped.

## Environment knobs

| Variable | Purpose |
| --- | --- |
| `TARGET_URL` | HTTPS endpoint the live checks hit (e.g. `https://example.com`). |
| `HTTPS_PROXY` / `https_proxy` | Proxy used for egress. Required (with `TARGET_URL`) to run the egress checks. |
| `NO_PROXY` | Standard no-proxy host list. Honoured by the curl and Python checks; the node, openssl, and java checks always go through `HTTPS_PROXY` and ignore it. |
| `CORP_CA_FINGERPRINT` | Expected corp CA SHA-256 fingerprint. Accepts uppercase/colon-separated or normalized form; when set, the system bundle is checked for that CA. |
| `TARGET_GIT_URL` | Opt-in: a real HTTPS git remote to exercise the git check (`TARGET_URL` is not a git remote, so git is skipped unless this is set). |
| `PROBE_CHECK_JAVA` | Opt-in: run the JVM egress check. The JVM is the documented exception (C-4) — skipped by default so a PEM-only run does not file a false Java bug. |
| `PROBE_CMD_TIMEOUT` | Per-tool subprocess timeout in seconds (default `30`). |

## JSON report schema

Top-level object:

```jsonc
{
  "schema_version": "1",
  "target_url": "https://example.com",   // from TARGET_URL ("" if unset)
  "proxy": "http://proxy:8080",           // from HTTPS_PROXY/https_proxy ("" if unset)
  "summary": { "total": 0, "passed": 0, "failed": 0, "skipped": 0 },
  "checks": [
    {
      "id": "...",          // stable check id (use as the bug title)
      "toolchain": "...",   // env | openssl | curl | python | node | git | java | probe
      "category": "...",    // contract | trust | egress | meta
      "status": "...",      // pass | fail | skip
      "expected": "...",
      "actual": "...",
      "detail": "...",
      "remediation": "..."  // suggested fix when status == fail
    }
  ]
}
```

`status` is always one of `pass`, `fail`, `skip`.

## Exit-code contract

Exit `0` iff no check has status `fail` (skips and passes are tolerated);
non-zero if any check failed.
