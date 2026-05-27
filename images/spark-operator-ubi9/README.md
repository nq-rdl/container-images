# spark-operator-ubi9

Kubeflow Spark Operator controller on Red Hat UBI9-minimal. Drop-in
replacement for the upstream operator image, rebuilt on a compliant base
with full supply-chain attestation.

Blueprint: [`kubeflow/spark-operator`](https://github.com/kubeflow/spark-operator)
Dockerfile, with runtime stage swapped to UBI9-minimal.

## Pull

```bash
podman pull ghcr.io/nq-rdl/spark-operator-ubi9:2.1.0
```

## Supported tags

| Tag | Meaning |
|-----|---------|
| `2.1.0` | Specific operator version, latest UBI9 patch |
| `2.1` | Latest patch of operator 2.1.x |
| `latest` | Latest operator version, latest UBI9 patch |

Pin by `@sha256:...` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Upstream | kubeflow/spark-operator v2.1.0 |
| Platforms | linux/amd64, linux/arm64 |
| User | 185 (non-root) |
| Binary | `/usr/bin/spark-operator` (static Go binary) |

## Usage with Helm

Override the operator image in your Helm values:

```yaml
image:
  repository: ghcr.io/nq-rdl/spark-operator-ubi9
  tag: "2.1.0"
```

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/spark-operator-ubi9:2.1.0 \
  --repo nq-rdl/container-images
```
