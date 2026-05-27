# Security Policy

## Supported versions

Security fixes target images tagged `latest` on `main`. Older tags are not
patched — pin by digest and rebuild to pick up fixes.

## Reporting a vulnerability

Please report security vulnerabilities through GitHub's private vulnerability
reporting flow:

<https://github.com/nq-rdl/container-images/security/advisories/new>

Do not open a public GitHub issue, pull request, discussion, or comment with
exploit details or sensitive information. Use the GitHub advisory thread to
share reproduction steps, affected images, impact, and any suggested fix.

After a report is submitted, maintainers will triage it in GitHub, coordinate
the fix in the private advisory, and publish a patched image and advisory when
appropriate.

## Automated scanning

All images are scanned with Trivy on every build. Published images are
rescanned daily. Results appear in the GitHub Security tab.

## Scope

Security-relevant areas include base image vulnerabilities, supply-chain
integrity (build provenance and SBOM attestations), runtime dependency CVEs,
and CI/CD workflow configuration.

This project does not operate a bug bounty program.
