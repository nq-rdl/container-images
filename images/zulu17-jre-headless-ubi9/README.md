# zulu17-jre-headless-ubi9

Azul Zulu JRE Headless 17 on Red Hat UBI9-minimal. Minimal production runtime
without GUI libraries. TCK-verified OpenJDK distribution with long-term
commercial support from Azul.

## Pull

```bash
podman pull ghcr.io/nq-rdl/zulu17-jre-headless-ubi9:latest
```

## Supported tags

- `17.0.19` — specific Zulu JRE version, latest UBI9 patch
- `17.0` — latest patch of Zulu JRE 17.0.x
- `latest` — latest Zulu JRE 17 version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Azul Zulu JRE Headless 17.0.19 |
| Platforms | linux/amd64, linux/arm64 |
| User | 1001 (non-root) |
| JAVA_HOME | `/usr/lib/jvm/zulu17` |

## Usage as base image

```dockerfile
FROM ghcr.io/nq-rdl/zulu17-jre-headless-ubi9:17.0.19

COPY target/my-app.jar /opt/app/
WORKDIR /opt/app
CMD ["-jar", "my-app.jar"]
```

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/zulu17-jre-headless-ubi9:latest \
  --repo nq-rdl/container-images
```
