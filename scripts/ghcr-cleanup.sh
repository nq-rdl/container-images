#!/usr/bin/env bash
#
# Manifest-aware GHCR cleanup for this repository's published images.
#
# Removes attestation referrer tags (sha256-<digest>) and orphaned untagged
# manifests left behind by repeated (daily) rebuilds, while KEEPING every
# real-tagged version AND the per-platform child manifests that its manifest
# list references. That preservation is the whole point: a multi-arch tag is an
# index pointing at untagged platform manifests, so deleting those children
# breaks the image — they are always kept.
#
# A package whose current tag cannot be resolved is skipped entirely (keep all),
# so a transient registry read never causes a destructive mistake.
#
# Usage:
#   scripts/ghcr-cleanup.sh            # dry run — list what would be deleted
#   scripts/ghcr-cleanup.sh --execute  # perform deletions
#
# Environment:
#   GHCR_ORG       org/owner (default: nq-rdl)
#   GHCR_PACKAGES  optional space/comma-separated package override; defaults to
#                  the set derived from images/*/ plus their -ubiN aliases
#   GH_TOKEN       token with read:packages + delete:packages (delete needs it;
#                  the default Actions GITHUB_TOKEN cannot delete package versions)
#
set -euo pipefail

ORG="${GHCR_ORG:-nq-rdl}"
EXECUTE=0
[ "${1:-}" = "--execute" ] && EXECUTE=1

# Packages this repo owns: each image dir name + its -ubiN-stripped alias.
derive_packages() {
  local d name
  for d in images/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
    if [[ "$name" =~ ^(.+)-ubi[0-9]+$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

if [ -n "${GHCR_PACKAGES:-}" ]; then
  read -ra PACKAGES <<< "${GHCR_PACKAGES//,/ }"
else
  mapfile -t PACKAGES < <(derive_packages)
fi

if [ "${#PACKAGES[@]}" -eq 0 ]; then
  echo "ERROR: no packages to process (run from repo root or set GHCR_PACKAGES)" >&2
  exit 1
fi

# Read a raw manifest: skopeo locally, docker buildx imagetools on CI runners.
manifest_raw() {
  local ref="$1"
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --raw "docker://${ref}" 2>/dev/null
  else
    docker buildx imagetools inspect --raw "${ref}" 2>/dev/null
  fi
}

DELLIST="$(mktemp)"
trap 'rm -f "$DELLIST"' EXIT
total_keep=0
total_del=0

for p in "${PACKAGES[@]}"; do
  if ! vers="$(gh api --paginate "/orgs/${ORG}/packages/container/${p}/versions?per_page=100" \
        --jq '.[] | [(.id|tostring), .name, ((.metadata.container.tags // []) | join(","))] | @tsv' 2>/dev/null)"; then
    printf '%-30s (not found in GHCR — skipping)\n' "$p"
    continue
  fi
  [ -z "$vers" ] && { printf '%-30s (no versions)\n' "$p"; continue; }

  declare -A keep=()
  real_digests=()
  while IFS=$'\t' read -r id digest tags; do
    [ -z "$id" ] && continue
    [ -z "$tags" ] && continue
    has_real=0
    IFS=',' read -ra tag_arr <<< "$tags"
    for t in "${tag_arr[@]}"; do
      case "$t" in sha256-*) ;; *) has_real=1 ;; esac
    done
    [ "$has_real" -eq 1 ] && real_digests+=("$digest")
  done <<< "$vers"

  # keep-set = every real-tagged digest + the children of its manifest list
  resolve_ok=1
  if [ "${#real_digests[@]}" -gt 0 ]; then
    for d in "${real_digests[@]}"; do
      keep["$d"]=1
      if ! raw="$(manifest_raw "ghcr.io/${ORG}/${p}@${d}")" || [ -z "$raw" ] \
           || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        resolve_ok=0
        break
      fi
      while IFS= read -r child; do
        [ -n "$child" ] && keep["$child"]=1
      done < <(printf '%s' "$raw" | jq -r 'if .manifests then .manifests[].digest else empty end')
    done
  fi
  if [ "$resolve_ok" -eq 0 ]; then
    printf '%-30s SKIP (could not resolve a tag; keeping ALL versions)\n' "$p"
    unset keep
    continue
  fi

  pkg_keep=0
  pkg_del=0
  while IFS=$'\t' read -r id digest tags; do
    [ -z "$id" ] && continue
    if [ -n "${keep[$digest]:-}" ]; then
      pkg_keep=$((pkg_keep + 1))
    else
      printf '%s\t%s\t%s\n' "$p" "$id" "${tags:-<UNTAGGED>}" >> "$DELLIST"
      pkg_del=$((pkg_del + 1))
    fi
  done <<< "$vers"
  printf '%-30s keep=%-3s delete=%s\n' "$p" "$pkg_keep" "$pkg_del"
  total_keep=$((total_keep + pkg_keep))
  total_del=$((total_del + pkg_del))
  unset keep
done

echo "----"
echo "TOTAL keep=${total_keep} delete=${total_del}"

if [ "$EXECUTE" -ne 1 ]; then
  echo "(dry run — re-run with --execute to delete)"
  exit 0
fi

echo "=== EXECUTING DELETIONS ==="
ok=0
fail=0
while IFS=$'\t' read -r p id tags; do
  [ -z "$id" ] && continue
  if gh api --method DELETE "/orgs/${ORG}/packages/container/${p}/versions/${id}" --silent 2>/tmp/ghcr-del.err; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "FAIL ${p}/${id} (${tags}): $(cat /tmp/ghcr-del.err)"
  fi
done < "$DELLIST"
echo "deleted=${ok} failed=${fail}"
[ "$fail" -eq 0 ]
