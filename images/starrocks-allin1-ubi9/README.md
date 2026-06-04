# starrocks-allin1-ubi9

StarRocks **allin1** single-node image (FE + BE under supervisor, with an nginx
feproxy) repackaged onto Red Hat UBI9. Intended for local development, demos, and
CI — **not** for Operator-managed production clusters (use `starrocks-fe-ubi9` /
`starrocks-be-ubi9` / `starrocks-cn-ubi9` for that).

Blueprint: [`StarRocks/starrocks`](https://github.com/StarRocks/starrocks)
`docker/dockerfiles/allin1/allin1-ubi.Dockerfile`, adapted UBI8 -> UBI9 by
repackaging `starrocks/artifacts-centos7`.

## Run

```bash
podman run -p 9030:9030 -p 8030:8030 ghcr.io/nq-rdl/starrocks-allin1-ubi9:4.1.1
# MySQL protocol on :9030, FE HTTP on :8030
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
| Runtime | StarRocks FE+BE + OpenJDK 11, supervisor, nginx feproxy |
| Platforms | linux/amd64 |
| Deploy dir | `/data/deploy/starrocks` |
| Default command | `./entrypoint.sh` (starts the single-node cluster) |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/starrocks-allin1-ubi9:4.1.1 \
  --repo nq-rdl/container-images
```
