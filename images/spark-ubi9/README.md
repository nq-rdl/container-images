# spark-ubi9

Apache Spark 3.5.6 runtime on Red Hat UBI9-minimal. Intended as a base image
for Spark driver and executor pods on Kubernetes.

Blueprint: [`apache/spark-docker`](https://github.com/apache/spark-docker)
`3.5.6/scala2.12-java17-ubuntu`, adapted for UBI9-minimal.

## Pull

```bash
podman pull ghcr.io/nq-rdl/spark-ubi9:3.5.6
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `3.5.6` | Specific Spark version, latest UBI9 patch |
| `3.5` | Latest patch of Spark 3.5.x |
| `latest` | Latest Spark version, latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Apache Spark 3.5.6 with OpenJDK 17 |
| Platforms | linux/amd64, linux/arm64 |
| User | 185 (non-root, Spark convention) |
| Spark Home | `/opt/spark` |

## Usage as base image

```dockerfile
FROM ghcr.io/nq-rdl/spark-ubi9:3.5.6

COPY my-app.jar /opt/spark/jars/
```

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/spark-ubi9:3.5.6
```
