# dbt-ubi9

dbt-core with Python on Red Hat UBI9-micro.

## Pull

```bash
podman pull ghcr.io/nq-rdl/dbt-ubi9:latest
```

## Supported tags

- `1.11.11` — specific dbt-core version, latest UBI9 patch
- `1.11` — latest patch of dbt-core 1.11.x
- `latest` — latest dbt-core version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-micro:9.5` |
| Runtime | dbt-core 1.11.11, Python 3.11 |
| Default adapter | dbt-postgres |
| Platforms | linux/amd64 |
| User | 1001 (non-root) |

## Build args

| Arg | Default | Description |
|-----|---------|-------------|
| `DBT_VERSION` | `1.11.11` | dbt-core version |
| `DBT_ADAPTER` | `dbt-postgres` | Adapter package (set empty to skip) |
| `PYTHON_VERSION` | `3.11` | Python minor version |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/dbt-ubi9:latest \
  --repo nq-rdl/container-images
```
