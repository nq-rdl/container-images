# zulu21-jre-headless-ubi9

Azul Zulu JRE Headless 21 on Red Hat UBI9-minimal. Minimal production runtime
without GUI libraries. TCK-verified OpenJDK distribution with long-term
commercial support from Azul.

## Pull

```bash
podman pull ghcr.io/nq-rdl/zulu21-jre-headless-ubi9:latest
```

## Supported tags

- `21.0.11` — specific Zulu JRE version, latest UBI9 patch
- `21.0` — latest patch of Zulu JRE 21.0.x
- `latest` — latest Zulu JRE 21 version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Azul Zulu JRE Headless 21.0.11 |
| Platforms | linux/amd64, linux/arm64 |
| User | 1001 (non-root) |
| JAVA_HOME | `/usr/lib/jvm/zulu21` |

## Usage as base image

```dockerfile
FROM ghcr.io/nq-rdl/zulu21-jre-headless-ubi9:21.0.11

COPY target/my-app.jar /opt/app/
WORKDIR /opt/app
CMD ["-jar", "my-app.jar"]
```

## Verify

```bash
cosign verify \
  --certificate-identity-regexp='^https://github.com/nq-rdl/container-images/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  ghcr.io/nq-rdl/zulu21-jre-headless-ubi9:latest
```
