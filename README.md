# RDL Container Image Catalog

UBI9-based container images for NQ RDL workloads. Built, scanned, signed, and SBOM-attested in CI.

## Available images

See the [`images/`](images/) directory for all available images and their documentation.

## Pull

```bash
podman pull ghcr.io/nq-rdl/bun-ubi9:latest
```

## Verify signature

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/bun-ubi9:latest
```

## Verify SBOM attestation

```bash
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/bun-ubi9:latest
```

## Tag conventions

| Tag | Meaning |
|-----|---------|
| `1.1.42` | Exact runtime version, immutable |
| `1.1` | Latest patch of minor |
| `latest` | Most recent stable build from `main` |
| `YYYYMMDD` | Nightly rebuild (CVE refresh) |

Pin by `@sha256:…` digest in production manifests.
