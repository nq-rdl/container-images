# bun-ubi9

Bun JavaScript runtime on Red Hat UBI9-minimal.

## Pull

```bash
podman pull ghcr.io/nq-rdl/bun-ubi9:latest
```

## Supported tags

- `1.1.42` — exact version
- `1.1` — latest patch
- `latest` — most recent build from `main`

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Bun 1.1.42 |
| Platforms | linux/amd64, linux/arm64 |
| User | 1001 (non-root) |

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/bun-ubi9:latest
```
