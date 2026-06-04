# starrocks-fe-ubi9

StarRocks FE (Frontend / coordinator) repackaged onto Red Hat UBI9, for deployment
via the [StarRocks Kubernetes Operator](https://github.com/StarRocks/starrocks-kubernetes-operator).

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/fe/fe-ubi.Dockerfile`, adapted from UBI8 to UBI9 and built by
repackaging `starrocks/artifacts-centos7`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/starrocks-fe-ubi9:4.1.1
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
| Runtime | StarRocks FE with OpenJDK 17 |
| Platforms | linux/amd64 |
| StarRocks Home | `/opt/starrocks` |
| Default command | none — supplied by the Operator (`fe_entrypoint.sh` is bundled) |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-fe-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
