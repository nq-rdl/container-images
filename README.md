# RDL Container Image Catalog

UBI9-based container images for Research Data Laboratory workloads. Built, scanned, signed, and SBOM-attested in CI.

## Available images

See the [`images/`](images/) directory for all available images and their documentation.

## Pull

```bash
podman pull ghcr.io/nq-rdl/bun-ubi9:latest
```

## Verify attestations

Build provenance and SBOM attestations are attached via GitHub-native attestation
(OCI 1.1 referrers). Verify with the GitHub CLI:

```bash
gh attestation verify oci://ghcr.io/nq-rdl/bun-ubi9:latest \
  --owner nq-rdl
```

## Tag conventions

See [CONTRIBUTING.md](CONTRIBUTING.md#image-naming-convention) for the full
naming standard. Pin by `@sha256:…` digest in production manifests.
