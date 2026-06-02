#!/usr/bin/env bash
# One-time, reachability-safe GHCR cleanup for THIS repo's packages.
# Keeps every tagged version AND every child manifest referenced by a tagged
# index (multi-arch safe). Dry-run by default; pass --apply to delete.
# Scope: images/*/ names plus their {service}-ubi{N} -> {service} aliases.
# Never touches packages outside that allowlist. Fail-closed on resolve errors.
set -euo pipefail

ORG="${GHCR_ORG:-nq-rdl}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

TOKEN="${GHCR_TOKEN:-$(gh auth token 2>/dev/null || true)}"
[ -n "$TOKEN" ] || { echo "ERROR: no token (set GHCR_TOKEN or run 'gh auth login')" >&2; exit 1; }
export GH_TOKEN="$TOKEN"   # gh api and skopeo use the SAME credential
GHCR_USER="${GHCR_USER:-$(gh api user --jq .login 2>/dev/null || true)}"
[ -n "$GHCR_USER" ] || { echo "ERROR: cannot resolve GHCR username (set GHCR_USER)" >&2; exit 1; }

if [ "$APPLY" = 1 ]; then MODE=APPLY; else MODE=DRY-RUN; fi

# Build the allowlist: image dirs + stripped aliases.
declare -A ALLOW=()
for d in images/*/; do
  name=$(basename "$d")
  [ -f "${d}Containerfile" ] || continue
  ALLOW["$name"]=1
  if [[ "$name" =~ ^(.+)-ubi[0-9]+$ ]]; then ALLOW["${BASH_REMATCH[1]}"]=1; fi
done
allow_keys="${!ALLOW[*]}"
echo "Allowlisted packages: ${allow_keys:-(none)}"
echo "Mode: ${MODE}"
echo

total_del=0
for pkg in "${!ALLOW[@]}"; do
  versions=$(gh api "/orgs/${ORG}/packages/container/${pkg}/versions" --paginate 2>/dev/null || echo "")
  [ -n "$versions" ] || { echo "skip ${pkg}: not found / unreadable"; continue; }

  declare -A KEEP=()
  resolve_ok=1

  # Keep every tagged version's own digest.
  while IFS= read -r d; do
    [ -n "$d" ] && KEEP["$d"]=1
  done < <(echo "$versions" | jq -r '.[] | select((.metadata.container.tags // []) | length > 0) | .name')

  # Keep every child manifest referenced by a tagged index (multi-arch safe).
  while IFS= read -r tagged; do
    [ -z "$tagged" ] && continue
    raw=$(skopeo inspect --raw --creds "${GHCR_USER}:${TOKEN}" "docker://ghcr.io/${ORG}/${pkg}@${tagged}" 2>/dev/null || true)
    if [ -z "$raw" ] || ! jq -e . >/dev/null 2>&1 <<< "$raw"; then
      echo "  WARN ${pkg}: cannot resolve/parse ${tagged} — keeping ALL versions (fail-closed)"
      resolve_ok=0
      break
    fi
    while IFS= read -r child; do
      [ -n "$child" ] && KEEP["$child"]=1
    done < <(jq -r 'if (.manifests | type) == "array" then .manifests[].digest else empty end' <<< "$raw")
  done < <(echo "$versions" | jq -r '.[] | select((.metadata.container.tags // []) | length > 0) | .name')

  if [ "$resolve_ok" -ne 1 ]; then unset KEEP; continue; fi

  while IFS=$'\t' read -r vid vname vtags; do
    [ -z "$vid" ] && continue
    if [ -n "${KEEP[$vname]:-}" ]; then
      echo "  KEEP   ${pkg} ${vname} [${vtags}]"
    else
      echo "  DELETE ${pkg} ${vname} [${vtags}]"
      total_del=$((total_del + 1))
      if [ "$APPLY" = 1 ]; then
        gh api --method DELETE "/orgs/${ORG}/packages/container/${pkg}/versions/${vid}"
      fi
    fi
  done < <(echo "$versions" | jq -r '.[] | [(.id|tostring), .name, ((.metadata.container.tags // []) | join(","))] | @tsv')

  unset KEEP
done

echo
if [ "$APPLY" = 1 ]; then
  echo "Deleted ${total_del} version(s)."
else
  echo "Would delete ${total_del} version(s). Re-run with --apply to perform deletions."
fi
