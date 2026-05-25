# Security policy

## Reporting a vulnerability

Email security@nq-rdl.example with details. Do not open a public issue.
Expect acknowledgement within 2 business days.

## Supported images

We patch CRITICAL and HIGH CVEs (per Trivy, ignore-unfixed=true) for images tagged `latest` on `main`.

## CVE response SLA

| Severity | Target |
|----------|--------|
| CRITICAL | Patched image within 72 hours of upstream fix |
| HIGH | Patched image within 7 days |

## Automated scanning

All images are scanned with Trivy on every build. Published images are rescanned daily at 14:00 UTC. Results appear in the GitHub Security tab.

## Verification

All images are signed with cosign (keyless, GitHub OIDC). See [README](README.md) for verify commands, or use `scripts/verify-image.sh`.
