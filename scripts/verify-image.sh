#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: verify-image.sh <image-ref>}"
IMAGE="${IMAGE#oci://}"

echo "==> Verifying attestations for ${IMAGE}..."
gh attestation verify "oci://${IMAGE}" --repo nq-rdl/container-images

echo "==> All verifications passed."
