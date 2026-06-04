# starrocks-cn-ubi9

StarRocks CN (Compute Node; shared-data / storage-compute separation) repackaged onto
Red Hat UBI9, for deployment via the StarRocks Kubernetes Operator (`starRocksCnSpec`).
CN shares the BE binary, started in compute-only mode via `cn_entrypoint.sh`.

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/be/be-ubi.Dockerfile` (CN role), adapted UBI8 -> UBI9 by
repackaging `starrocks/artifacts-centos7`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/starrocks-cn-ubi9:4.1.1
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `4.1.1` / `4.1` | StarRocks 4.1.1, latest UBI9 patch |
| `3.3.22` / `3.3` | StarRocks 3.3.22, latest UBI9 patch |
| `latest` | Latest StarRocks (4.1 line), latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | StarRocks CN (BE binary, compute-only) + OpenJDK 17 |
| Platforms | linux/amd64 |
| StarRocks Home | `/opt/starrocks` (`cn -> be`) |
| Default command | none — supplied by the Operator |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-cn-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
