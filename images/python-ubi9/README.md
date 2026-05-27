# python-ubi9

Python runtime on Red Hat UBI9-minimal. Built for each supported minor
version via a shared Containerfile and `PYTHON_VERSION` build arg.

## Pull

```bash
podman pull ghcr.io/nq-rdl/python-ubi9:3.12
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `3.11` | Python 3.11.x on UBI9-minimal |
| `3.12` | Python 3.12.x on UBI9-minimal |
| `latest` | Alias for `3.12` |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | CPython (RPM-packaged) |
| Platforms | linux/amd64 |
| User | 1001 (non-root) |
| Includes | python3, pip, setuptools |

## Usage as base image

```dockerfile
FROM ghcr.io/nq-rdl/python-ubi9:3.12

USER 0
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
USER 1001

COPY . .
CMD ["python", "app.py"]
```

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/python-ubi9:3.12
```
