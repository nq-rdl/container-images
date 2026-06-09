# jamovi-ubi9

The [jamovi](https://www.jamovi.org) statistical spreadsheet (server build) on UBI9, rebuilt
from source at tag **v2.7.30**. Chained on `jamovi-deps-ubi9`. Multi-stage build of the Python
server (Cython core), the Node/vite web client, the C++ analysis engine, the `jmvcore` + `jmv` +
`plots` R modules, and the i18n bundles.

## Pull

```bash
podman pull ghcr.io/nq-rdl/jamovi-ubi9:latest
```

## Supported tags

- `2.7.30` — specific jamovi version
- `2.7` — latest patch of the 2.7 line
- `latest`

Pin by `@sha256:…` digest in production manifests.

## Run

```bash
podman run --rm -p 41337:41337 ghcr.io/nq-rdl/jamovi-ubi9:latest
# open http://127.0.0.1:41337
```

jamovi runs across three origins for security; see jamovi's
[`docker-compose.yaml`](https://github.com/jamovi/jamovi/blob/main/docker-compose.yaml) for the
`JAMOVI_HOST_A/B/C` and `JAMOVI_ACCESS_KEY` environment variables when exposing it beyond
localhost. `JAMOVI_ALLOW_ARBITRARY_CODE` is `false` by default (the `Rj` editor is disabled —
do not enable it unless you understand the risks).

## Details

| Field | Value |
|-------|-------|
| Base | `ghcr.io/nq-rdl/jamovi-deps-ubi9:2.7.30` |
| jamovi | v2.7.30 (commit `771860d`) |
| Runtime | Python 3.12 server, C++ engine, R 4.5.0 modules |
| Port | 41337 |
| Platforms | linux/amd64 |
| User | root (matches upstream) |

## Key differences from upstream `jamovi/jamovi:2.7.x`

| Upstream (Ubuntu noble) | This image (UBI9) |
|---|---|
| Build context = repo root | Pinned recursive `git clone` (a `source` stage); jamovi's submodules (`jmv`, `readstat`, `i18n`, `plots`) are fetched `--recursive` at a fixed commit |
| system `python3` (3.12 on noble) | `python3.12` installed explicitly (UBI9's `/usr/bin/python3` is 3.9); CMD calls `/usr/bin/python3.12` |
| `COPY …/python3.12/dist-packages` | `…/site-packages` (Debian uses `dist-packages`; RHEL uses upstream-Python `site-packages`) |
| `protoc` (3.21) for both C++ and Python | C++ engine uses system protoc 3.14 (ABI-matched to `-lprotobuf`); Python `--python_out` uses pinned protoc 34.0 (matches `protobuf==7.34.0`); `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python` startup guard |
| `libnanomsg.so` COPYed from Debian multiarch path | `nanomsg` installed via dnf (EPEL); RHEL has no `/usr/lib/x86_64-linux-gnu` |
| `libasio-dev` | `boost::asio` from `boost-devel` (AlmaLinux) — no standalone asio |
| `FROM r-base AS jamovi` (final) | `FROM ${BASE_CONTAINER} AS jamovi` so the last FROM is UBI-rooted (policy) |

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/jamovi-ubi9:latest \
  --repo nq-rdl/container-images
```
