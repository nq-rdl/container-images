#!/usr/bin/env bash
# Repin a chained image's `ARG BASE_CONTAINER=<repo>:<tag>@sha256:<digest>` default to the
# digest its tag currently resolves to in GHCR. This finalizes the bootstrap placeholder digest a
# brand-new chain ships with (see tests/test-chained-bases-reachable.sh) after the chain's first
# publish. Idempotent and safe to run before publish: an unpublished tag is reported and skipped,
# never rewritten.
#
# Usage:
#   scripts/repin-chained-base.sh                       # repin every chained image under images/
#   scripts/repin-chained-base.sh images/jamovi-ubi9    # repin one image dir
#
# Requires crane (declared in pyproject.toml [tool.pixi.dependencies]; run via `pixi run -- ...`)
# and authentication to GHCR for repos that are private/unpublished
# (echo "$GH_TOKEN" | crane auth login ghcr.io -u <user> --password-stdin).
set -euo pipefail

[ -d images ] || { echo "ERROR: run from the repo root (images/ not found from $(pwd))"; exit 1; }
command -v crane >/dev/null 2>&1 || { echo "ERROR: crane not on PATH (try: pixi run -- $0 ...)"; exit 1; }

# Collect target Containerfiles: explicit dirs from argv, else every chained image under images/.
declare -a CFS=()
if [ "$#" -gt 0 ]; then
  for d in "$@"; do CFS+=("${d%/}/Containerfile"); done
else
  shopt -s nullglob
  for cf in images/*/Containerfile; do
    grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" && CFS+=("$cf")
  done
fi

CHANGED=0
SKIPPED=0
for cf in "${CFS[@]}"; do
  [ -f "$cf" ] || { echo "SKIP: $cf not found"; SKIPPED=$((SKIPPED + 1)); continue; }
  # Last `ARG BASE_CONTAINER=` default (extraction kept in sync with tests/test-chained-bases-*.sh).
  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//' || true)
  case "$val" in
    *:*@sha256:*) ;;
    *) echo "SKIP: $cf — BASE_CONTAINER='$val' is not <repo>:<tag>@sha256:<digest>"; SKIPPED=$((SKIPPED + 1)); continue ;;
  esac
  repo_tag="${val%@*}"          # ghcr.io/nq-rdl/<img>:<tag>
  old="${val##*@}"             # sha256:<hex>

  if ! new=$(crane digest "$repo_tag" 2>/dev/null); then
    echo "SKIP: $cf — ${repo_tag} not published yet (bootstrap); rerun after the chain publishes"
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  if [ "$new" = "$old" ]; then
    echo "OK:   $cf — already pinned to ${new}"
    continue
  fi
  # Literal (non-regex) replacement — registry hostnames contain dots.
  OLD_REF="${repo_tag}@${old}" NEW_REF="${repo_tag}@${new}" \
    perl -0pi -e 's/\Q$ENV{OLD_REF}\E/$ENV{NEW_REF}/g' "$cf"
  echo "REPIN: $cf — ${old} -> ${new}"
  CHANGED=$((CHANGED + 1))
done

echo ""
echo "Repinned ${CHANGED}, skipped ${SKIPPED}."
if [ "$CHANGED" -gt 0 ]; then
  echo "Next: update the BOOTSTRAP PLACEHOLDER comment(s) to note the published digest, add a"
  echo "changie 'Fixed' fragment, and run 'pixi run policy-check-chained-bases-reachable'."
fi
