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

# Identify chained (bake_target) images; build them via docker buildx bake so they are
# available for scanning. Building them standalone would fail on the unresolved
# ${BASE_CONTAINER} ARG.
# WARNING: with RUNTIME=podman, chained images are NOT built automatically — pre-build
# them manually in dependency order (foundation before base-notebook) using
# --build-arg BASE_CONTAINER=<locally-built-tag>.
BAKE_TAG="${TAG:-2026.6.0}"
BAKE_IMAGES=()
if [ "$RUNTIME" = "docker" ] && command -v docker >/dev/null && docker buildx version >/dev/null 2>&1; then
  mapfile -t BAKE_DIRS < <(grep -lR --include=image.yaml 'bake_target:' "$IMAGES_DIR" | xargs -r -n1 dirname)
  if [ "${#BAKE_DIRS[@]}" -gt 0 ]; then
    # Only bake if not already present in the local daemon (e.g. smoke ran first).
    _first_bake_name=$(basename "${BAKE_DIRS[0]}")
    _first_bake_tag="ghcr.io/nq-rdl/${_first_bake_name}:${BAKE_TAG}"
    if ! docker image inspect "$_first_bake_tag" &>/dev/null; then
      echo "==> Baking chained images for Trivy scan: ${BAKE_DIRS[*]}"
      docker buildx bake --file "${REPO_ROOT}/docker-bake.hcl" --load datascience
    fi
    for d in "${BAKE_DIRS[@]}"; do
      BAKE_IMAGES+=("$d")
    done
  fi
fi

echo "==> Trivy vulnerability scan (CRITICAL,HIGH — ignoring unfixed)"
for cf in "${CONTAINERFILES[@]}"; do
  dir=$(dirname "$cf")
  name=$(basename "$dir")

  # Chained images were bake-built above with their canonical ghcr.io tag; skip the
  # standalone build path that would fail on the unresolved ${BASE_CONTAINER} ARG.
  if printf '%s\n' "${BAKE_IMAGES[@]:-}" | grep -qx "$dir"; then
    tag="ghcr.io/nq-rdl/${name}:${BAKE_TAG}"
  else
    tag="localhost/smoke-test/${name}:latest"
    if ! "$RUNTIME" image inspect "$tag" &>/dev/null; then
      echo "  Building ${name} (not yet built)..."
      if ! "$RUNTIME" build -t "$tag" -f "$cf" "$dir"; then
        fail "${name} build failed"
        continue
      fi
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
