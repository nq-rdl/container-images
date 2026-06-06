#!/usr/bin/env bash
set -euo pipefail

if [ "${SKIP_SMOKE:-0}" = "1" ]; then
  echo "SKIP_SMOKE=1 — skipping smoke tests"
  exit 0
fi

if [ -n "${PRE_COMMIT_FROM_REF:-}" ] && [ -n "${PRE_COMMIT_TO_REF:-}" ]; then
  if ! git diff --name-only "${PRE_COMMIT_FROM_REF}..${PRE_COMMIT_TO_REF}" -- images/ | grep -q .; then
    echo "No changes under images/ — skipping smoke tests"
    exit 0
  fi
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

read_smoke_args() {
  local cmd_file="$1/smoke-cmd"
  if [ -f "$cmd_file" ]; then
    head -1 "$cmd_file"
  fi
}

echo "==> Phase 1: Building images with ${RUNTIME}"
declare -a BUILT=()

# Build bake_target (chained) images via docker buildx bake; map their tags into BUILT.
# WARNING: with RUNTIME=podman, chained images are NOT built automatically — pre-build
# them manually in dependency order (foundation before base-notebook) using
# --build-arg BASE_CONTAINER=<locally-built-tag>.
BAKE_TAG="${TAG:-2026.6.0}"
BAKE_IMAGES=()
if [ "$RUNTIME" = "docker" ] && command -v docker >/dev/null && docker buildx version >/dev/null 2>&1; then
  mapfile -t BAKE_DIRS < <(grep -lR --include=image.yaml 'bake_target:' "$IMAGES_DIR" | xargs -r -n1 dirname)
  if [ "${#BAKE_DIRS[@]}" -gt 0 ]; then
    echo "==> Baking chained images: ${BAKE_DIRS[*]}"
    docker buildx bake --file "${REPO_ROOT}/docker-bake.hcl" --load datascience
    for d in "${BAKE_DIRS[@]}"; do
      name=$(basename "$d")
      tag="ghcr.io/nq-rdl/${name}:${BAKE_TAG}"
      BAKE_IMAGES+=("$d")
      BUILT+=("${tag}|${name}|${d}")
    done
  fi
fi

for cf in "${CONTAINERFILES[@]}"; do
  dir=$(dirname "$cf")
  # Skip images already built via docker buildx bake.
  if printf '%s\n' "${BAKE_IMAGES[@]:-}" | grep -qx "$dir"; then continue; fi
  name=$(basename "$dir")
  tag="localhost/smoke-test/${name}:latest"
  echo "  Building ${name}..."
  if "$RUNTIME" build -t "$tag" -f "$cf" "$dir"; then
    BUILT+=("${tag}|${name}|${dir}")
    echo "  OK: ${name} built"
  else
    fail "${name} build failed"
  fi
done

if [ ${#BUILT[@]} -eq 0 ]; then
  echo "No images built — skipping remaining tests"
  [ "$FAILURES" -gt 0 ] && exit 1
  exit 0
fi

echo "==> Phase 2: Container runtime smoke test (${RUNTIME})"
for entry in "${BUILT[@]}"; do
  IFS='|' read -r tag name dir <<< "$entry"
  smoke_args=$(read_smoke_args "$dir")

  echo "  Running ${name}..."
  # shellcheck disable=SC2086
  if timeout 60 "$RUNTIME" run --rm "$tag" $smoke_args; then
    echo "  OK: ${name} runs (${RUNTIME})"
  else
    fail "${name} failed to run (${RUNTIME})"
  fi
done

echo "==> Phase 3: k3d cluster smoke test"
echo "  Creating cluster ${CLUSTER_NAME}..."
k3d cluster create "$CLUSTER_NAME" --wait --timeout 120s --no-lb

for entry in "${BUILT[@]}"; do
  IFS='|' read -r tag name dir <<< "$entry"
  pod_name="smoke-${name}"
  smoke_args=$(read_smoke_args "$dir")

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
  if [ -n "$smoke_args" ]; then
    # shellcheck disable=SC2086
    kubectl run "$pod_name" \
      --image="$tag" \
      --restart=Never \
      --image-pull-policy=Never \
      -- $smoke_args
  else
    kubectl run "$pod_name" \
      --image="$tag" \
      --restart=Never \
      --image-pull-policy=Never
  fi

  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=30s 2>/dev/null; then
    echo "  OK: ${name} completed in k3d"
  elif kubectl wait --for=jsonpath='{.status.phase}'=Running "pod/${pod_name}" --timeout=30s 2>/dev/null; then
    echo "  OK: ${name} runs in k3d"
  else
    phase=$(kubectl get "pod/${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    fail "${name} pod did not start (phase: ${phase})"
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
