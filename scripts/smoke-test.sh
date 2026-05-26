#!/usr/bin/env bash
set -euo pipefail

if [ "${SKIP_SMOKE:-0}" = "1" ]; then
  echo "SKIP_SMOKE=1 — skipping smoke tests"
  exit 0
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

for cmd in k3d kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "error: ${cmd} not found" >&2
    echo "hint: run 'make install-deps' to install dependencies" >&2
    exit 1
  fi
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGES_DIR="${REPO_ROOT}/images"

mapfile -t CONTAINERFILES < <(find "$IMAGES_DIR" -name Containerfile -type f)

if [ ${#CONTAINERFILES[@]} -eq 0 ]; then
  echo "No Containerfiles found — nothing to smoke test"
  exit 0
fi

CLUSTER_NAME="smoke-$$"
FAILURES=0

cleanup() {
  echo "==> Cleaning up k3d cluster ${CLUSTER_NAME}..."
  k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "  FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

echo "==> Phase 1: Building images with ${RUNTIME}"
declare -a BUILT_TAGS=()
for cf in "${CONTAINERFILES[@]}"; do
  dir=$(dirname "$cf")
  name=$(basename "$dir")
  tag="localhost/smoke-test/${name}:latest"
  echo "  Building ${name}..."
  if "$RUNTIME" build -t "$tag" -f "$cf" "$dir"; then
    BUILT_TAGS+=("${tag}|${name}")
    echo "  OK: ${name} built"
  else
    fail "${name} build failed"
  fi
done

if [ ${#BUILT_TAGS[@]} -eq 0 ]; then
  echo "No images built — skipping k3d tests"
  [ "$FAILURES" -gt 0 ] && exit 1
  exit 0
fi

echo "==> Phase 2: k3d cluster smoke test"
echo "  Creating cluster ${CLUSTER_NAME}..."
k3d cluster create "$CLUSTER_NAME" --wait --timeout 120s --no-lb

for entry in "${BUILT_TAGS[@]}"; do
  tag="${entry%%|*}"
  name="${entry##*|}"
  pod_name="smoke-${name}"

  echo "  Importing ${name} into k3d..."
  if [ "$RUNTIME" = "podman" ]; then
    tmptar=$(mktemp /tmp/smoke-XXXXXX.tar)
    podman save "$tag" -o "$tmptar"
    k3d image import "$tmptar" -c "$CLUSTER_NAME"
    rm -f "$tmptar"
  else
    k3d image import "$tag" -c "$CLUSTER_NAME"
  fi

  echo "  Running pod ${pod_name}..."
  kubectl run "$pod_name" \
    --image="$tag" \
    --restart=Never \
    --image-pull-policy=Never \
    --command -- /bin/sh -c "echo smoke-ok"

  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=60s 2>/dev/null; then
    echo "  OK: ${name} runs in k3d"
  else
    phase=$(kubectl get "pod/${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    fail "${name} pod did not succeed (phase: ${phase})"
    kubectl logs "pod/${pod_name}" 2>/dev/null || true
  fi
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} smoke test(s) failed"
  exit 1
else
  echo "All smoke tests passed"
fi
