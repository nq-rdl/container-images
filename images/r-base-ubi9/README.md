# r-base-ubi9

Posit **R 4.5.0** runtime on Red Hat UBI9 — the [`rstudio/r-base`](https://github.com/rstudio/r-docker)
(now `posit/r-base`) equivalent, rebuilt on UBI9. R is installed from Posit's prebuilt
`rhel-9` binary to `/opt/R/4.5.0`. This is the reusable foundation for R workloads in this
catalog and the base of the jamovi chain (`jamovi-deps-ubi9` → `jamovi-ubi9`).

## Pull

```bash
podman pull ghcr.io/nq-rdl/r-base-ubi9:latest
```

## Supported tags

- `4.5.0` — specific R version, latest UBI9 patch
- `4.5` — latest patch of R 4.5.x
- `latest` — latest R version, latest UBI9 patch

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `registry.access.redhat.com/ubi9/ubi:9.8` |
| Runtime | R 4.5.0 (Posit `rhel-9` build, `/opt/R/4.5.0`) |
| Extras | Pandoc 2.19.2 (rmarkdown/knitr backend) |
| Platforms | linux/amd64 |
| User | root |

## Differences from upstream `rstudio/r-base:4.5.0-noble`

| Upstream (Ubuntu noble) | This image (UBI9) |
|---|---|
| `FROM rockylinux:9` / `ubuntu:noble` | `FROM ubi9/ubi` (digest-pinned) |
| R via `OS_IDENTIFIER` for the distro | R via Posit `rhel-9` RPM, checksum-verified |
| `dnf config-manager --set-enabled crb` | UBI has no `crb` repo id, and its CodeReady subset lacks `flexiblas-devel`; instead EPEL + AlmaLinux 9 (priority=200) supply the gaps (see below) |
| TinyTeX pre-installed in the base | **Dropped** — the `tinytex` R package (installed downstream) bootstraps TeX Live on demand; keeps the base lean |

## Supply chain: why AlmaLinux + EPEL repos

UBI9's package repositories are a deliberately restricted subset of RHEL9. Several packages the
R + jamovi stack needs are **absent from every UBI repo** (BaseOS/AppStream/CodeReady/EPEL) —
most critically `flexiblas-devel`, which is a **hard RPM dependency of Posit's R itself**, plus
`protobuf*` and `boost*` (needed downstream by `RProtoBuf` and the jamovi engine).

To stay on a UBI base while filling these gaps, this image enables:

- **EPEL 9** (`nanomsg`, `glpk`, `libRmath`) — installed via the official Fedora `epel-release` RPM.
- **AlmaLinux 9** BaseOS/AppStream/CRB (`flexiblas-devel`, `protobuf`, `boost`) — GPG-verified,
  RHEL-ABI-compatible, and pinned at **`priority=200`** so the UBI/Red Hat repos (default
  priority 99) always win. AlmaLinux can therefore only supply packages Red Hat omits from UBI;
  it never shadows a UBI package.

This is a deliberate, bounded deviation from the catalog's usual "prefer conda-forge, avoid
EPEL" norm, accepted because Posit's R RPM cannot be satisfied on a pure-UBI repo set.

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/r-base-ubi9:latest \
  --repo nq-rdl/container-images
```
