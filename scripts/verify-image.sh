#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: verify-image.sh <image-ref>}"
IDENTITY="^https://github.com/nq-rdl/container-images/.*"
ISSUER="https://token.actions.githubusercontent.com"

echo "==> Verifying signature for ${IMAGE}..."
cosign verify \
  --certificate-identity-regexp="${IDENTITY}" \
  --certificate-oidc-issuer="${ISSUER}" \
  "${IMAGE}"

echo "==> Verifying SBOM attestation for ${IMAGE}..."
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity-regexp="${IDENTITY}" \
  --certificate-oidc-issuer="${ISSUER}" \
  "${IMAGE}"

echo "==> All verifications passed."
