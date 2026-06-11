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
#   scripts/repin-chained-base.sh images/jamovi-ubi9/Containerfile  # same (path normalised)
#   pixi run repin-chained-bases                        # via pixi
#
# Requires crane (declared in pyproject.toml [tool.pixi.dependencies]; run via `pixi run -- ...`)
# and authentication to GHCR for repos that are private/unpublished:
#   echo "$GH_TOKEN" | crane auth login ghcr.io -u <user> --password-stdin
#   echo "$GH_TOKEN" | pixi run -- crane auth login ghcr.io -u <user> --password-stdin
#
# Error-class semantics (mirroring tests/test-chained-bases-reachable.sh):
#   * tag not published yet (MANIFEST_UNKNOWN / NAME_UNKNOWN / 404) -> SKIP (bootstrap)
#   * any other crane error (DENIED / auth / network / rate-limit)  -> FAIL (fail-closed, non-zero exit)
#   * crane succeeds but stdout is empty or not sha256:<64hex>      -> FAIL (malformed output guard)
#   * Containerfile lacks @sha256: in BASE_CONTAINER                -> SKIP (not a chained image)
set -euo pipefail

[ -d images ] || { echo "ERROR: run from the repo root (images/ not found from $(pwd))"; exit 1; }
command -v crane >/dev/null 2>&1 || { echo "ERROR: crane not on PATH (try: pixi run -- $0 ...)"; exit 1; }

# Does a crane error message indicate an absent tag/repo (vs auth/network/other)?
# Same classification logic as tests/test-chained-bases-reachable.sh is_absent_error().
# GHCR returns MANIFEST_UNKNOWN for absent tags on existing repos; NAME_UNKNOWN / 404 for
# absent repos entirely. Anything else (DENIED, connection refused, rate-limit) falls through
# to the fail-closed path.
is_absent_error() {
  grep -qiE 'MANIFEST_UNKNOWN|NAME_UNKNOWN|status code 404|: 404' <<<"$1"
}

# Collect target Containerfiles: explicit dirs from argv (normalised), else every chained image.
# shopt nullglob is scoped to the subshell-in-process-substitution or the block below to avoid
# leaking the option past the glob that uses it.
declare -a CFS=()
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    # Normalise: strip a trailing /Containerfile suffix so both 'images/x' and
    # 'images/x/Containerfile' produce the same 'images/x/Containerfile' target.
    # Without this, the original ${d%/}/Containerfile appended /Containerfile a second time,
    # turning 'images/x/Containerfile' into 'images/x/Containerfile/Containerfile' — a path
    # that silently resolves to a SKIP.
    dir="${arg%/Containerfile}"
    CFS+=("${dir%/}/Containerfile")
  done
else
  # Scope nullglob to this block; unset it afterwards so it does not affect any later code.
  shopt -s nullglob
  for cf in images/*/Containerfile; do
    grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" && CFS+=("$cf")
  done
  shopt -u nullglob
fi

CHANGED=0
SKIPPED=0
ERRORS=0

for cf in "${CFS[@]}"; do
  [ -f "$cf" ] || { echo "SKIP: $cf not found"; SKIPPED=$((SKIPPED + 1)); continue; }

  # Last `ARG BASE_CONTAINER=` default (extraction kept in sync with tests/test-chained-bases-*.sh).
  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//' || true)
  case "$val" in
    *:*@sha256:*) ;;
    *) echo "SKIP: $cf — BASE_CONTAINER='$val' is not <repo>:<tag>@sha256:<digest>"; SKIPPED=$((SKIPPED + 1)); continue ;;
  esac

  repo_tag="${val%@*}"   # ghcr.io/nq-rdl/<img>:<tag>
  old="${val##*@}"       # sha256:<hex>

  # Probe the tag — capture stderr only (order matters: `2>&1 >/dev/null` directs stderr into
  # the command-substitution capture first, THEN sends stdout to /dev/null; reversing this would
  # discard the error text before we can classify it). This matches the documented pattern in
  # tests/test-chained-bases-reachable.sh lines 116-124.
  if ! err=$(crane digest "$repo_tag" 2>&1 >/dev/null); then
    if is_absent_error "$err"; then
      echo "SKIP: $cf — ${repo_tag} not published yet (bootstrap); rerun after the chain publishes"
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    # Any other error class (DENIED, auth, network, rate-limit) — fail-closed.
    echo "ERROR: $cf — crane failed for ${repo_tag}: ${err}"
    ERRORS=$((ERRORS + 1)); continue
  fi

  # Re-run to get stdout (the digest). A separate call avoids the capture-order complexity of
  # capturing both stdout and stderr from a single invocation while preserving the exit-code
  # check above. Auth succeeded (the probe above passed), so a second failure here is treated
  # as an unexpected error.
  if ! new=$(crane digest "$repo_tag" 2>/dev/null); then
    echo "ERROR: $cf — crane digest succeeded on probe but failed on reread for ${repo_tag}"
    ERRORS=$((ERRORS + 1)); continue
  fi

  # Validate the returned digest before any file rewrite. An empty or malformed $new would
  # produce a broken ARG BASE_CONTAINER line. Require the canonical sha256:<64-lowercase-hex>
  # format; fail-closed on anything else.
  if [[ ! "$new" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: $cf — crane returned unexpected output for ${repo_tag}: '${new}' (expected sha256:<64hex>)"
    ERRORS=$((ERRORS + 1)); continue
  fi

  if [ "$new" = "$old" ]; then
    echo "OK:   $cf — already pinned to ${new}"
    continue
  fi

  # Literal (non-regex) replacement — registry hostnames contain dots.
  OLD_REF="${repo_tag}@${old}" NEW_REF="${repo_tag}@${new}" \
    perl -0pi -e 's/\Q$ENV{OLD_REF}\E/$ENV{NEW_REF}/g' "$cf"

  # F6: update the BOOTSTRAP PLACEHOLDER comment block when (and only when) it is present with
  # the expected wording. The replacement is idempotent: if the comment already says "pinned"
  # (from a prior run), neither pattern matches, so the file is untouched at the comment level.
  # If the comment wording does not match the known placeholder block (bespoke comment, already
  # updated, or no comment at all), the sed is a no-op and we note it in the 'Next:' output.
  #
  # The placeholder pattern has two slightly different openings in the two jamovi Containerfiles:
  #   "a BOOTSTRAP PLACEHOLDER digest. r-base-ubi9 is not published yet,"
  #   "a BOOTSTRAP PLACEHOLDER digest (jamovi-deps-ubi9 is unpublished,"
  # We match the shared "BOOTSTRAP PLACEHOLDER" anchor and replace the full comment line with a
  # concise pinned-digest note, leaving subsequent lines (the rest of the old block) intact so
  # they are overwritten by the literal-text replacement below. We delete the multi-line block
  # that precedes the ARG line using a range delete: from the first "BOOTSTRAP PLACEHOLDER" line
  # to the last line before "ARG BASE_CONTAINER=".
  COMMENT_WAS_UPDATED=false
  if grep -qF "BOOTSTRAP PLACEHOLDER" "$cf"; then
    # Replace the entire BOOTSTRAP PLACEHOLDER comment block (from "# ARG BASE_CONTAINER default:
    # a BOOTSTRAP PLACEHOLDER" through the line immediately before "ARG BASE_CONTAINER=") with a
    # single concise note. Perl range delete: match the opening line of the block and delete
    # through (not including) the ARG line.
    perl -0pi -e '
      s{(?:^|\n)(# ARG BASE_CONTAINER default: a BOOTSTRAP PLACEHOLDER[^\n]*(?:\n#[^\n]*)*)(\nARG BASE_CONTAINER=)}{
        "\n# ARG BASE_CONTAINER default: pinned to the published GHCR digest via scripts/repin-chained-base.sh." . $2
      }em
    ' "$cf"
    # Verify the replacement took effect (if it did, BOOTSTRAP PLACEHOLDER is gone).
    if ! grep -qF "BOOTSTRAP PLACEHOLDER" "$cf"; then
      COMMENT_WAS_UPDATED=true
    fi
  fi

  echo "REPIN: $cf — ${old} -> ${new}"
  CHANGED=$((CHANGED + 1))

  if ! $COMMENT_WAS_UPDATED; then
    echo "       NOTE: BOOTSTRAP PLACEHOLDER comment not found or already updated in $cf"
  fi
done

echo ""
echo "Repinned ${CHANGED}, skipped ${SKIPPED}, errors ${ERRORS}."
if [ "$CHANGED" -gt 0 ]; then
  echo "Next: add a changie 'Fixed' fragment ('changie new'), run"
  echo "'pixi run policy-check-chained-bases-reachable' to confirm all pins PASS, then commit."
fi

# Fail-closed: any error-class crane failure (auth/network/malformed output) must produce a
# non-zero exit so callers and CI notice rather than silently receiving a partial repin.
if [ "$ERRORS" -gt 0 ]; then
  echo "FATAL: ${ERRORS} image(s) failed with non-bootstrap errors; see ERROR lines above."
  exit 1
fi
exit 0
