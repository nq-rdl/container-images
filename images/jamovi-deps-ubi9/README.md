# jamovi-deps-ubi9

The **R-package dependency layer** for jamovi on UBI9. Chained on `r-base-ubi9`, it adds the
~200 CRAN packages jamovi needs (the two `install.packages()` blocks from jamovi's upstream
`deps-Dockerfile`) plus `jmvReadWrite`. This is the heavy base on which `jamovi-ubi9` is built;
it mirrors upstream `jamovi/jamovi-deps`.

## Pull

```bash
podman pull ghcr.io/nq-rdl/jamovi-deps-ubi9:latest
```

## Supported tags

- `2.7.30` — tracks the jamovi version whose dependency set this layer provides
- `2.7` — latest patch of the 2.7 line
- `latest`

Pin by `@sha256:…` digest in production manifests.

## Details

| Field | Value |
|-------|-------|
| Base | `ghcr.io/nq-rdl/r-base-ubi9:4.5.0` |
| Contents | ~200 CRAN packages + `jmvReadWrite` (R 4.5.0) |
| Package source | Posit P3M `rhel9` binaries (`2025-05-25` snapshot) + jamovi's patched-package repo, source fallback via the build toolchain |
| Platforms | linux/amd64 |

## Differences from upstream `jamovi/jamovi deps-Dockerfile @ v2.7.30`

| Upstream (Ubuntu noble) | This image (UBI9) |
|---|---|
| `FROM rstudio/r-base:4.5.0-noble` | `FROM r-base-ubi9` (Posit R 4.5.0 on UBI9) |
| `apt install` system libs | `dnf install` equivalents (protobuf/boost from AlmaLinux, glpk from EPEL — inherited from `r-base-ubi9`, `priority=200`) |
| `CRAN_MIRROR=…/__linux__/noble/…` | `…/__linux__/rhel9/…` (binary R packages for el9) |
| `gfortran`, `libglpk40`, `libgmp10` | `gcc-gfortran`, `glpk` (EPEL), `gmp` |

The CRAN package list, `INSTALL_opts`, and the pinned `jmvReadWrite` commit are unchanged from
upstream. Every package is `library()`-loaded immediately after install, so a missing runtime
library or silent repo drift fails the build rather than shipping a broken layer.

## Verify

```bash
gh attestation verify oci://ghcr.io/nq-rdl/jamovi-deps-ubi9:latest \
  --repo nq-rdl/container-images
```
