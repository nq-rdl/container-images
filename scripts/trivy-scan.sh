#!/usr/bin/env bash
set -euo pipefail

if [ "${SKIP_TRIVY:-0}" = "1" ]; then
  echo "SKIP_TRIVY=1 — skipping Trivy scan"
  exit 0
fi

if [ -n "${PRE_COMMIT_FROM_REF:-}" ] && [ -n "${PRE_COMMIT_TO_REF:-}" ]; then
  if ! git diff --name-only "${PRE_COMMIT_FROM_REF}..${PRE_COMMIT_TO_REF}" -- images/ | grep -q .; then
    echo "No changes under images/ — skipping Trivy scan"
    exit 0
  fi
fi

if ! command -v trivy &>/dev/null; then
  echo "error: trivy not found" >&2
  echo "hint: run 'pixi install' to install dependencies" >&2
  exit 1
fi

if command -v docker &>/dev/null; then
  RUNTIME=docker
elif command -v podman &>/dev/null; then
  RUNTIME=podman
else
  echo "error: no container runtime (docker/podman) found" >&2
  echo "hint: run 'make install-deps' to install dependencies" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGES_DIR="${REPO_ROOT}/images"

mapfile -t CONTAINERFILES < <(find "$IMAGES_DIR" -name Containerfile -type f)

if [ ${#CONTAINERFILES[@]} -eq 0 ]; then
  echo "No Containerfiles found — nothing to scan"
  exit 0
fi

FAILURES=0

fail() {
  echo "  FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

echo "==> Trivy vulnerability scan (CRITICAL,HIGH — ignoring unfixed)"
for cf in "${CONTAINERFILES[@]}"; do
  dir=$(dirname "$cf")
  name=$(basename "$dir")
  tag="localhost/smoke-test/${name}:latest"

  if ! "$RUNTIME" image inspect "$tag" &>/dev/null; then
    echo "  Building ${name} (not yet built)..."
    if ! "$RUNTIME" build -t "$tag" -f "$cf" "$dir"; then
      fail "${name} build failed"
      continue
    fi
  fi

  echo "  Scanning ${name}..."
  if trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 "$tag"; then
    echo "  OK: ${name} clean"
  else
    fail "${name} has fixable CRITICAL/HIGH vulnerabilities"
  fi
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} image(s) failed Trivy scan"
  exit 1
else
  echo "All images passed Trivy scan"
fi
