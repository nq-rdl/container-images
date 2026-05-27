#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: verify-image.sh <image-ref>}"
IMAGE="${IMAGE#oci://}"

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required but not installed." >&2
  echo "Install: https://cli.github.com/" >&2
  exit 1
fi

if ! gh attestation verify --help &>/dev/null 2>&1; then
  echo "Error: 'gh attestation' subcommand not available. Update gh or run: gh extension install github/gh-attestation" >&2
  exit 1
fi


echo "==> Verifying attestations for ${IMAGE}..."
gh attestation verify "oci://${IMAGE}" --repo nq-rdl/container-images

echo "==> All verifications passed."
