# go-ubi9

Go toolchain on Red Hat UBI9-minimal — a UBI-rooted, digest-pinned replacement for
`golang:*-alpine` build stages.

## Pull

```bash
podman pull ghcr.io/nq-rdl/go-ubi9:latest
```

## Supported tags

- `1.26.4` — specific Go version, latest UBI9 patch
- `1.26` — latest patch of Go 1.26.x
- `latest` — latest Go version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| Runtime | Go 1.26.4 (official go.dev tarball, SHA256-verified) |
| Platforms | linux/amd64 |
| User | 1001 (non-root) |
| `GOTOOLCHAIN` | `local` (image is pinned to its Go version) |

This is a **build/toolchain** image. CGO is not configured (no `gcc`/glibc headers): it targets
`CGO_ENABLED=0` static binaries. The resulting binary is shipped by the consumer on a minimal
runtime such as `ubi9-micro`.

## Build args

| Arg | Default | Description |
|-----|---------|-------------|
| `GO_VERSION` | `1.26.4` | Go toolchain version |
| `GO_SHA256_AMD64` | _(pinned)_ | SHA256 of `go${GO_VERSION}.linux-amd64.tar.gz` |
| `GO_SHA256_ARM64` | _(pinned)_ | SHA256 of `go${GO_VERSION}.linux-arm64.tar.gz` |

## Usage as a build stage

```dockerfile
FROM ghcr.io/nq-rdl/go-ubi9@sha256:<digest> AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /tmp/server ./cmd/server

FROM registry.access.redhat.com/ubi9/ubi-micro:9.5@sha256:<digest>
COPY --from=builder /tmp/server /server
USER 1001
ENTRYPOINT ["/server"]
```

> The build runs as uid 1001 with `GOPATH=/home/app/go` and `GOCACHE=/home/app/.cache/go-build`
> (both writable). Write build outputs to a writable path (e.g. `/tmp`), not `/`.

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/go-ubi9:latest \
  --repo nq-rdl/container-images
```
