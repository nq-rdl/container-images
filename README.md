# RDL Container Image Catalog

UBI9-based container images for Research Data Laboratory workloads. Built, scanned, and attested in CI.

## Available images

See the [`images/`](images/) directory for all available images and their documentation.

## Pull

```bash
podman pull ghcr.io/nq-rdl/bun-ubi9:latest
```

## Verify attestations

Build provenance and SBOM attestations are generated via GitHub-native attestation
and stored in GitHub's attestation API (not pushed to the registry). Verify with the GitHub CLI:

```bash
gh attestation verify oci://ghcr.io/nq-rdl/bun-ubi9:latest \
  --repo nq-rdl/container-images
```

## Reproducibility

Base images are pinned by digest in each `Containerfile`, so a rebuild uses the
exact same base until a `base-drift.yml` PR bumps it. Images are rebuilt on
merged changes, not on a daily schedule.

## Tag conventions

See [CONTRIBUTING.md](CONTRIBUTING.md#image-naming-convention) for the full
naming standard. Pin by `@sha256:…` digest in production manifests.
