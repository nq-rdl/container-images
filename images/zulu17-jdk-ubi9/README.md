# zulu17-jdk-ubi9

Azul Zulu JDK 17 on Red Hat UBI9-minimal. TCK-verified OpenJDK distribution
with long-term commercial support from Azul.

## Pull

```bash
podman pull ghcr.io/nq-rdl/zulu17-jdk-ubi9:latest
```

## Supported tags

- `17.0.19` — specific Zulu JDK version, latest UBI9 patch
- `17.0` — latest patch of Zulu JDK 17.0.x
- `latest` — latest Zulu JDK 17 version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Azul Zulu JDK 17.0.19 |
| Platforms | linux/amd64, linux/arm64 |
| User | 1001 (non-root) |
| JAVA_HOME | `/usr/lib/jvm/zulu17` |

## Usage as base image

```dockerfile
FROM ghcr.io/nq-rdl/zulu17-jdk-ubi9:17.0.19

COPY target/my-app.jar /opt/app/
WORKDIR /opt/app
CMD ["-jar", "my-app.jar"]
```

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/zulu17-jdk-ubi9:latest
```
