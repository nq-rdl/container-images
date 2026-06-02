# CI/CD Janitor Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the CI pipeline from generating orphaned GHCR manifests (so issue #36's scheduled cleanup janitor becomes unnecessary) by digest-pinning all base images and rebuilding only on merged commits.

**Architecture:** Pin every external base `FROM` to its multi-arch **index** digest → builds become deterministic w.r.t. the base. Remove the daily `build.yml` schedule → the registry changes only on push/PR/dispatch/merged-drift-PR. A new in-repo, FROM-aware `base-drift.yml` opens digest-bump PRs (zero registry writes); the Trivy rescan (expanded to every published tag) is the CVE radar. A one-time, reachability-safe `ghcr-purge.sh` clears the existing backlog.

**Tech Stack:** GitHub Actions, Bash, `skopeo`/`crane`, `yq`/`jq`, conftest/OPA, hadolint, pixi, changie.

**Resolved base index digests (write-time, 2026-06-03; the drift-checker will bump if stale):**

| Base ref | Index digest (OCI image index, amd64+arm64+…) |
|---|---|
| `registry.access.redhat.com/ubi9/ubi-minimal:9.5` | `sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44` |
| `registry.access.redhat.com/ubi9/ubi:9.5` | `sha256:d07a5e080b8a9b3624d3c9cfbfada9a6baacd8e6d4065118f0e80c71ad518044` |
| `registry.access.redhat.com/ubi9/ubi-micro:9.5` | `sha256:839f16991579b023d4452eadd0efa925e438f8b73063afe4f75bdc6cf7a09b12` |
| `docker.io/library/golang:1.24` | `sha256:d2d2bc1c84f7e60d7d2438a3836ae7d0c847f4888464e7ec9ba3a1339a1ee804` |

**CI gates every change must satisfy** (don't break these): `lint.yml` → actionlint (all workflows) + shellcheck (`scripts/`+`tests/` `*.sh`) + gitleaks; `policy.yml` → conftest Containerfile + image.yaml policies + `tests/test-build-workflow-tags.sh`. `base_image.rego` checks only the **final** `FROM` must start with `registry.access.redhat.com/ubi` or `registry.redhat.io/ubi`.

**File map:**
- Modify: `images/{bun,dbt,pyspark,python,spark-operator,spark,zulu17-jdk,zulu17-jre-headless,zulu21-jdk,zulu21-jre-headless}-ubi9/Containerfile` (10 files — pin bases)
- Modify: `.github/workflows/build.yml` (remove schedule; scope aliases)
- Modify: `.github/workflows/trivy-scheduled-rescan.yml` (scan all tags)
- Modify: `.github/dependabot.yml` (drop docker entries)
- Modify: `tests/test-build-workflow-tags.sh` (no-schedule assertions)
- Modify: `.github/workflows/policy.yml` (run base-pinning test); `pyproject.toml` (pixi task)
- Modify: `CONTRIBUTING.md`, `README.md`
- Create: `tests/test-base-images-pinned.sh`
- Create: `.github/workflows/base-drift.yml`
- Create: `.github/workflows/validate-base-pins.yml`
- Create: `scripts/ghcr-purge.sh`
- Create: `.changes/unreleased/*.yaml` (changie fragment)

---

## Task 1: Digest-pin all base images (TDD)

**Files:**
- Create: `tests/test-base-images-pinned.sh`
- Modify: all 10 `images/*/Containerfile`
- Modify: `pyproject.toml`, `.github/workflows/policy.yml`

- [ ] **Step 1: Write the failing test**

Create `tests/test-base-images-pinned.sh`:

```bash
#!/usr/bin/env bash
# Asserts every external-registry FROM in images/*/Containerfile is pinned by @sha256:.
# Stage refs (FROM <stage>), COPY --from, and FROM scratch are exempt.
set -euo pipefail

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

shopt -s nullglob
for cf in images/*/Containerfile; do
  while IFS= read -r line; do
    # Strip 'FROM', any --platform flag, and trailing 'AS <stage>'; take the image ref.
    ref=$(echo "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/--platform=[^[:space:]]+[[:space:]]+//; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//')
    img=$(echo "$ref" | awk '{print $1}')

    [ "$img" = "scratch" ] && { pass "$cf: FROM scratch (exempt)"; continue; }
    # Stage-to-stage ref: no registry/repo separator, no tag, no digest.
    if [[ "$img" != *"/"* && "$img" != *"."* && "$img" != *":"* && "$img" != *"@"* ]]; then
      pass "$cf: FROM $img (stage ref, exempt)"; continue
    fi

    if [[ "$img" == *"@sha256:"* && "$img" != *'${'* ]]; then
      pass "$cf: $img is digest-pinned"
    else
      fail "$cf: '$img' is NOT digest-pinned (use ':tag@sha256:...', no \${...})"
    fi
  done < <(grep -iE '^[[:space:]]*FROM[[:space:]]' "$cf")
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} unpinned base(s) found"; exit 1
else
  echo "All external base images are digest-pinned"; exit 0
fi
```

- [ ] **Step 2: Run it; verify RED**

Run: `chmod +x tests/test-base-images-pinned.sh && bash tests/test-base-images-pinned.sh`
Expected: FAIL lines for all 10 images (e.g. `'registry.access.redhat.com/ubi9/ubi-minimal:${UBI_VERSION}' is NOT digest-pinned`), exit 1.

- [ ] **Step 3: Pin the 8 single-stage ubi-minimal images**

In each of these files, replace the two lines
`ARG UBI_VERSION=9.5` + `FROM registry.access.redhat.com/ubi9/ubi-minimal:${UBI_VERSION}`
with the single line:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44
```

Files: `images/bun-ubi9/Containerfile`, `images/pyspark-ubi9/Containerfile`, `images/spark-ubi9/Containerfile`, `images/zulu17-jdk-ubi9/Containerfile`, `images/zulu17-jre-headless-ubi9/Containerfile`, `images/zulu21-jdk-ubi9/Containerfile`, `images/zulu21-jre-headless-ubi9/Containerfile`.

For `images/python-ubi9/Containerfile` the `ARG UBI_VERSION=9.5` (line 3) and the `FROM` (line 6) are **not** adjacent — `ARG PYTHON_VERSION=3.12` sits between them. Delete only the `ARG UBI_VERSION=9.5` line, and pin the FROM:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44
```

(Keep `ARG PYTHON_VERSION=3.12` and the later `ARG PYTHON_VERSION` re-declaration.)

- [ ] **Step 4: Pin `dbt-ubi9` (3 stages)**

In `images/dbt-ubi9/Containerfile`:
- Delete **both** `ARG UBI_VERSION=9.5` lines (line 9 and line 37).
- Line 12 → `FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44 AS builder`
- Line 35 → `FROM registry.access.redhat.com/ubi9/ubi:9.5@sha256:d07a5e080b8a9b3624d3c9cfbfada9a6baacd8e6d4065118f0e80c71ad518044 AS runtime-rootfs`
- Line 53 → `FROM registry.access.redhat.com/ubi9/ubi-micro:9.5@sha256:839f16991579b023d4452eadd0efa925e438f8b73063afe4f75bdc6cf7a09b12`

(Keep `ARG PYTHON_VERSION=3.11` at line 38; `--releasever 9` stays hardcoded.)

- [ ] **Step 5: Pin `spark-operator-ubi9` (golang builder + ubi runtime)**

In `images/spark-operator-ubi9/Containerfile`:
- Delete `ARG UBI_VERSION=9.5` (line 9) and `ARG GO_VERSION=1.24` (line 11).
- Line 16 → `FROM golang:1.24@sha256:d2d2bc1c84f7e60d7d2438a3836ae7d0c847f4888464e7ec9ba3a1339a1ee804 AS builder`
- Line 37 → `FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:a50731d3397a4ee28583f1699842183d4d24fadcc565c4688487af9ee4e13a44`

(Keep `ARG SPARK_OPERATOR_VERSION`, `ARG TINI_VERSION` global ARGs.)

- [ ] **Step 6: Run the test; verify GREEN**

Run: `bash tests/test-base-images-pinned.sh`
Expected: all PASS, `All external base images are digest-pinned`, exit 0.

- [ ] **Step 7: Verify policy + hadolint still pass**

Run: `pixi run policy-check-containerfiles && pixi run lint-containerfiles`
Expected: conftest reports no failures (final FROM is still a UBI base); hadolint clean (digest pin satisfies DL3006).

- [ ] **Step 8: Wire the test into pixi and CI**

In `pyproject.toml`, under `[tool.pixi.tasks]` add:

```toml
policy-check-base-pinning = "bash tests/test-base-images-pinned.sh"
```

and add it to the `policy-check` aggregate:

```toml
[tool.pixi.tasks.policy-check]
depends-on = ["policy-check-containerfiles", "policy-check-image-meta", "policy-check-workflow-tags", "policy-check-base-pinning"]
```

In `.github/workflows/policy.yml`, in the `workflow-tags` job, add a step after the existing tag-compliance step:

```yaml
      - name: Validate base images are digest-pinned
        run: bash tests/test-base-images-pinned.sh
```

- [ ] **Step 9: Commit**

```bash
git add images/*/Containerfile tests/test-base-images-pinned.sh pyproject.toml .github/workflows/policy.yml
git commit -m "fix: digest-pin all base images to eliminate rebuild churn (#36)"
```

---

## Task 2: Remove the daily build schedule (TDD)

**Files:**
- Modify: `tests/test-build-workflow-tags.sh`
- Modify: `.github/workflows/build.yml`

- [ ] **Step 1: Add failing assertions to the workflow-tags test**

In `tests/test-build-workflow-tags.sh`, insert before the final `echo ""` summary block:

```bash
# Test: no schedule/cron trigger (daily rebuild orphaned a new digest every day — see #36)
if grep -qE '^[[:space:]]*schedule:' "$WORKFLOW" || grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$WORKFLOW"; then
  fail "build workflow still has a schedule/cron trigger (daily rebuild generates orphaned manifests)"
else
  pass "no schedule/cron trigger (rebuilds are commit/dispatch-driven)"
fi

# Test: commit/dispatch triggers remain
if grep -qE '^[[:space:]]*pull_request:' "$WORKFLOW"; then
  pass "pull_request trigger present"
else
  fail "missing pull_request trigger"
fi
if grep -qE '^[[:space:]]*workflow_dispatch:' "$WORKFLOW"; then
  pass "workflow_dispatch trigger present"
else
  fail "missing workflow_dispatch trigger"
fi
```

- [ ] **Step 2: Run it; verify RED**

Run: `bash tests/test-build-workflow-tags.sh`
Expected: FAIL `build workflow still has a schedule/cron trigger`, exit 1.

- [ ] **Step 3: Remove the schedule trigger from `build.yml`**

In `.github/workflows/build.yml`, delete these two lines from the `on:` block:

```yaml
  schedule:
    - cron: '0 6 * * *'
```

- [ ] **Step 4: Remove the schedule branch in `discover`**

In the `set-matrix` step, replace:

```bash
          if [[ "${EVENT_NAME}" == "schedule" ]] \
             || [[ "${INPUT_IMAGE}" == "all" ]]; then
```

with:

```bash
          if [[ "${INPUT_IMAGE}" == "all" ]]; then
```

(The `EVENT_NAME` env var is now unused by this branch but still set; leave it — it does no harm and avoids churn. The `else` git-diff branch already handles push-to-main.)

- [ ] **Step 5: Run test (GREEN) + actionlint**

Run: `bash tests/test-build-workflow-tags.sh && pixi run lint-actions`
Expected: all PASS incl. `no schedule/cron trigger`; actionlint clean.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build.yml tests/test-build-workflow-tags.sh
git commit -m "fix: drop daily build schedule; rebuild only on commit/dispatch (#36)"
```

---

## Task 3: Scope alias publishing to the build matrix

**Files:**
- Modify: `.github/workflows/build.yml` (the `publish-aliases` job)

- [ ] **Step 1: Add `discover` to the job's needs and pass the matrix**

In `.github/workflows/build.yml`, change the `publish-aliases` job header:

```yaml
  publish-aliases:
    if: github.event_name != 'pull_request'
    needs: [discover, build]
```

- [ ] **Step 2: Replace the `for image_dir in images/*/` loop header**

In the `Publish convenience aliases` step, add `MATRIX` to `env:` and change the loop to iterate only built images:

```yaml
      - name: Publish convenience aliases
        env:
          OWNER: ${{ github.repository_owner }}
          MATRIX: ${{ needs.discover.outputs.matrix }}
        run: |
          set -euo pipefail
          mapfile -t BUILT < <(echo "$MATRIX" | jq -r '[.[].image] | unique | .[]')
          for image_name in "${BUILT[@]}"; do
            image_dir="images/${image_name}/"
            [ -d "$image_dir" ] || continue
```

Delete the old `for image_dir in images/*/` line and the old `image_name=$(basename "$image_dir")` line (the loop variable is now `image_name`). The rest of the loop body is unchanged.

- [ ] **Step 3: Verify the loop still closes correctly + actionlint**

Run: `pixi run lint-actions`
Expected: actionlint clean. Manually confirm the `done` for the loop is intact and every `${image_name}`/`${image_dir}` reference resolves.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "refactor: scope alias publishing to the built image matrix (#36)"
```

---

## Task 4: Expand the Trivy rescan to every published tag

**Files:**
- Modify: `.github/workflows/trivy-scheduled-rescan.yml`

- [ ] **Step 1: Replace the `discover` job to emit {image, tag} pairs**

Replace the `discover` job in `.github/workflows/trivy-scheduled-rescan.yml` with:

```yaml
  discover:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.set-matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v6

      - name: Install yq
        run: |
          YQ_VERSION=4.44.6
          curl -fsSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
          chmod +x /usr/local/bin/yq

      - id: set-matrix
        run: |
          set -euo pipefail
          MATRIX="[]"
          while IFS= read -r dir; do
            [ -z "$dir" ] && continue
            name=$(basename "$dir")
            yaml="${dir}/image.yaml"
            [ -f "$yaml" ] || continue
            if yq -e '.build_matrix' "$yaml" >/dev/null 2>&1; then
              TAGS=$(yq -r '[.build_matrix.versions[].tags[]] | unique | .[]' "$yaml")
            else
              TAGS=$(yq -r '((.tags // []) + ["latest"]) | unique | .[]' "$yaml")
            fi
            while IFS= read -r tag; do
              [ -z "$tag" ] && continue
              MATRIX=$(echo "$MATRIX" | jq --arg i "$name" --arg t "$tag" '. + [{"image":$i,"tag":$t}]')
            done <<< "$TAGS"
          done < <(find images -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/Containerfile' \; -print)
          echo "matrix=$(echo "$MATRIX" | jq -c '.')" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Update the `rescan` job to use the {image,tag} matrix**

Replace the `rescan` job's `if`, `strategy`, and scan/upload steps with:

```yaml
  rescan:
    needs: discover
    if: needs.discover.outputs.matrix != '[]'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJson(needs.discover.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v6

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Scan published image
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ghcr.io/${{ github.repository_owner }}/${{ matrix.image }}:${{ matrix.tag }}
          format: sarif
          output: trivy-rescan-${{ matrix.image }}-${{ matrix.tag }}.sarif
          severity: CRITICAL,HIGH
          exit-code: '0'

      - if: always()
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: trivy-rescan-${{ matrix.image }}-${{ matrix.tag }}.sarif
          category: trivy-rescan-${{ matrix.image }}-${{ matrix.tag }}
```

- [ ] **Step 3: actionlint**

Run: `pixi run lint-actions`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/trivy-scheduled-rescan.yml
git commit -m "feat: rescan every published tag, not just :latest (#36)"
```

---

## Task 5: Add the in-repo base drift-checker; remove inert Dependabot docker entries

**Files:**
- Create: `.github/workflows/base-drift.yml`
- Modify: `.github/dependabot.yml`

- [ ] **Step 1: Create `.github/workflows/base-drift.yml`**

```yaml
name: Base Image Drift Check

on:
  schedule:
    - cron: '0 7 * * 1'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  discover:
    runs-on: ubuntu-latest
    outputs:
      images: ${{ steps.set.outputs.images }}
    steps:
      - uses: actions/checkout@v6
      - id: set
        run: |
          set -euo pipefail
          IMAGES=$(find images -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/Containerfile' \; -printf '%f\n' \
                   | jq -R -s -c 'split("\n") | map(select(length > 0))')
          echo "images=$IMAGES" >> "$GITHUB_OUTPUT"

  drift:
    needs: discover
    if: needs.discover.outputs.images != '[]'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        image: ${{ fromJson(needs.discover.outputs.images) }}
    steps:
      - uses: actions/checkout@v6
      - uses: imjasonh/setup-crane@v0.4

      - name: Resolve drift and validate new index
        id: drift
        env:
          IMAGE: ${{ matrix.image }}
        run: |
          set -euo pipefail
          cf="images/${IMAGE}/Containerfile"
          yaml="images/${IMAGE}/image.yaml"
          changed=0

          # Platforms this image must support (default linux/amd64).
          mapfile -t WANT < <(yq -r '(.platforms // ["linux/amd64"])[]' "$yaml" 2>/dev/null || echo "linux/amd64")

          while IFS= read -r line; do
            spec=$(echo "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//' | awk '{print $1}')
            case "$spec" in *"@sha256:"*) ;; *) continue ;; esac
            reftag="${spec%@*}"
            old="${spec#*@}"
            new=$(crane digest "$reftag")
            [ "$new" = "$old" ] && continue

            # Validate the new digest is an index covering every wanted platform (fail-closed).
            have=$(crane manifest "${reftag}@${new}" | jq -r '[.manifests[]?.platform | "\(.os)/\(.architecture)"] | join(" ")')
            for p in "${WANT[@]}"; do
              if ! grep -qw "$p" <<< "$have"; then
                echo "::error::${reftag}@${new} missing platform ${p}; skipping ${IMAGE}"
                exit 0
              fi
            done

            sed -i "s#${reftag}@${old}#${reftag}@${new}#g" "$cf"
            echo "drift: ${reftag} ${old} -> ${new}"
            changed=1
          done < <(grep -iE '^[[:space:]]*FROM[[:space:]]' "$cf")

          echo "changed=${changed}" >> "$GITHUB_OUTPUT"

      - name: Open or update bump PR
        if: steps.drift.outputs.changed == '1'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          IMAGE: ${{ matrix.image }}
        run: |
          set -euo pipefail
          branch="base-drift/${IMAGE}"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git checkout -B "$branch"
          git add "images/${IMAGE}/Containerfile"
          git commit -m "image(${IMAGE}): bump base image digest"
          git push -f origin "$branch"
          if [ -z "$(gh pr list --head "$branch" --state open --json number -q '.[0].number')" ]; then
            gh pr create --head "$branch" --base main \
              --title "image(${IMAGE}): bump base image digest" \
              --body "Automated base-image digest update for \`${IMAGE}\` (validated as a multi-arch index covering its declared platforms). Merging triggers a rebuild+push of the new digest."
          else
            echo "PR already open for ${branch}; force-push updated it."
          fi
```

> **Note (GITHUB_TOKEN limitation):** PRs opened by `GITHUB_TOKEN` do **not** trigger `pull_request` CI. That is acceptable here because the drift job itself validates the new digest is a platform-complete index before committing, and `build.yml` + `validate-base-pins` run on merge (push to `main`). If pre-merge PR CI is later wanted, add a PAT secret and use it for `git push`/`gh pr create`.

- [ ] **Step 2: Remove the 10 `docker` entries from `.github/dependabot.yml`**

Edit `.github/dependabot.yml` so only the `github-actions` update block remains:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
    groups:
      actions:
        patterns: ["*"]
    commit-message:
      prefix: "ci"
```

- [ ] **Step 3: actionlint + yaml sanity**

Run: `pixi run lint-actions && pixi run pre-commit-run check-yaml || true`
Expected: actionlint clean (it does not flag `imjasonh/setup-crane`).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/base-drift.yml .github/dependabot.yml
git commit -m "feat: FROM-aware base drift-checker; remove inert dependabot docker entries (#36)"
```

---

## Task 6: Add the registry-backed multi-arch pin validation (PR check)

**Files:**
- Create: `.github/workflows/validate-base-pins.yml`

- [ ] **Step 1: Create `.github/workflows/validate-base-pins.yml`**

```yaml
name: Validate Base Pins

on:
  pull_request:
    paths: ['images/**', '.github/workflows/validate-base-pins.yml']
  push:
    branches: [main]
    paths: ['images/**']

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: imjasonh/setup-crane@v0.4

      - name: Assert each pinned base is an index covering declared platforms
        run: |
          set -euo pipefail
          rc=0
          for cf in images/*/Containerfile; do
            dir=$(dirname "$cf")
            yaml="${dir}/image.yaml"
            mapfile -t WANT < <(yq -r '(.platforms // ["linux/amd64"])[]' "$yaml" 2>/dev/null || echo "linux/amd64")
            while IFS= read -r line; do
              spec=$(echo "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//' | awk '{print $1}')
              case "$spec" in *"@sha256:"*) ;; *) continue ;; esac
              have=$(crane manifest "$spec" | jq -r '[.manifests[]?.platform | "\(.os)/\(.architecture)"] | join(" ")')
              for p in "${WANT[@]}"; do
                if ! grep -qw "$p" <<< "$have"; then
                  echo "FAIL: ${cf}: ${spec} is not an index covering ${p} (has: ${have:-none})"
                  rc=1
                fi
              done
              echo "OK: ${cf}: ${spec} covers ${WANT[*]}"
            done < <(grep -iE '^[[:space:]]*FROM[[:space:]]' "$cf")
          done
          exit "$rc"
```

- [ ] **Step 2: actionlint**

Run: `pixi run lint-actions`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/validate-base-pins.yml
git commit -m "test: require pinned bases to be multi-arch indexes covering declared platforms (#36)"
```

---

## Task 7: Reachability-safe one-time GHCR purge script (TDD-lite)

**Files:**
- Create: `scripts/ghcr-purge.sh`

- [ ] **Step 1: Create `scripts/ghcr-purge.sh`**

```bash
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

# Build the allowlist: image dirs + stripped aliases.
declare -A ALLOW=()
for d in images/*/; do
  name=$(basename "$d")
  [ -f "${d}Containerfile" ] || continue
  ALLOW["$name"]=1
  if [[ "$name" =~ ^(.+)-ubi[0-9]+$ ]]; then ALLOW["${BASH_REMATCH[1]}"]=1; fi
done
echo "Allowlisted packages: ${!ALLOW[*]}"
echo "Mode: $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)"
echo

total_del=0
for pkg in "${!ALLOW[@]}"; do
  versions=$(gh api "/orgs/${ORG}/packages/container/${pkg}/versions" --paginate 2>/dev/null || echo "")
  [ -n "$versions" ] || { echo "skip ${pkg}: not found / unreadable"; continue; }

  # keep-set: tagged digests + their referenced children.
  declare -A KEEP=()
  resolve_ok=1
  while IFS= read -r d; do
    [ -n "$d" ] && KEEP["$d"]=1
  done < <(echo "$versions" | jq -r '.[] | select((.metadata.container.tags // []) | length > 0) | .name')

  while IFS= read -r tagged; do
    [ -z "$tagged" ] && continue
    raw=$(skopeo inspect --raw --creds "x:${TOKEN}" "docker://ghcr.io/${ORG}/${pkg}@${tagged}" 2>/dev/null || true)
    if [ -z "$raw" ]; then echo "  WARN ${pkg}: cannot resolve ${tagged} — keeping all (fail-closed)"; resolve_ok=0; break; fi
    while IFS= read -r child; do
      [ -n "$child" ] && KEEP["$child"]=1
    done < <(echo "$raw" | jq -r '.manifests[]?.digest // empty')
  done < <(echo "$versions" | jq -r '.[] | select((.metadata.container.tags // []) | length > 0) | .name')

  if [ "$resolve_ok" -ne 1 ]; then unset KEEP; continue; fi

  while IFS=$'\t' read -r vid vname vtags; do
    [ -z "$vid" ] && continue
    if [ -n "${KEEP[$vname]:-}" ]; then
      echo "  KEEP ${pkg} ${vname} [${vtags}]"
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
echo "$([ "$APPLY" = 1 ] && echo "Deleted" || echo "Would delete") ${total_del} version(s)."
[ "$APPLY" = 1 ] || echo "Re-run with --apply to perform deletions."
```

- [ ] **Step 2: shellcheck must pass (CI gate)**

Run: `pixi run lint-shell`
Expected: no shellcheck findings for `scripts/ghcr-purge.sh`. Fix any quoting issues before committing.

- [ ] **Step 3: Syntax + safe dry-run smoke (read-only)**

Run: `bash -n scripts/ghcr-purge.sh && chmod +x scripts/ghcr-purge.sh`
Then a real read-only dry-run (lists keep/delete, deletes nothing): `bash scripts/ghcr-purge.sh`
Expected: prints the allowlist, `Mode: DRY-RUN`, KEEP/DELETE lines, and a non-zero "Would delete N version(s)". Confirm every current `:latest`/version tag and its children show `KEEP`.

- [ ] **Step 4: Commit**

```bash
git add scripts/ghcr-purge.sh
git commit -m "feat: reachability-safe one-time GHCR purge script (#36)"
```

---

## Task 8: Docs + changelog

**Files:**
- Modify: `CONTRIBUTING.md`, `README.md`
- Create: `.changes/unreleased/*.yaml`

- [ ] **Step 1: Update `CONTRIBUTING.md` Containerfile conventions**

Replace the bullet `- Pin base image and runtime versions via \`ARG\`` with:

```markdown
- Pin the base image by digest (`registry.access.redhat.com/ubi9/ubi-minimal:9.5@sha256:…`);
  the `base-drift.yml` workflow opens a PR to bump the digest when the upstream tag moves.
  Pin runtime versions via `ARG`.
```

- [ ] **Step 2: Update the `CONTRIBUTING.md` "Production usage" note**

Replace `Tags are mutable — a UBI security rebuild updates the image behind the same tag.` with:

```markdown
Tags are mutable — merging a base-digest bump (or any image change) rebuilds and
moves the tag to the new digest. Rebuilds are commit-driven, not a daily cron.
```

- [ ] **Step 3: Add a "Rollback" subsection to `CONTRIBUTING.md`** (after "Production usage")

```markdown
### Rollback

Tags are digest-pinned in git, so rollback is a git revert:

1. `git revert <digest-bump-commit>` (or restore the previous `@sha256:` in the
   image's `Containerfile`) and merge.
2. The merge to `main` rebuilds and re-points the tag to the previous digest.
   Or, for an immediate fix, `workflow_dispatch` **Build Images** with the
   specific `image` from the last known-good commit.
```

- [ ] **Step 4: Update `README.md`**

After the "Verify attestations" section, add:

```markdown
## Reproducibility

Base images are pinned by digest in each `Containerfile`, so a rebuild uses the
exact same base until a `base-drift.yml` PR bumps it. Images are rebuilt on
merged changes, not on a daily schedule.
```

- [ ] **Step 5: Add a changie fragment**

Create `.changes/unreleased/Fixed-20260603-120000.yaml`:

```yaml
kind: Fixed
body: 'Eliminate GHCR orphaned-manifest churn at the source: digest-pin all base images, rebuild only on merged commits (no daily cron), add a FROM-aware base drift-checker, scan every published tag in the Trivy rescan, and add a reachability-safe one-time purge — superseding the scheduled cleanup janitor (#36).'
time: 2026-06-03T12:00:00Z
```

- [ ] **Step 6: Validate changie + commit**

Run: `bash scripts/check-changie-fragment.sh hint || true`
Expected: no error (fragment present).

```bash
git add CONTRIBUTING.md README.md .changes/unreleased/Fixed-20260603-120000.yaml
git commit -m "docs: digest-pin guidance, rollback, and reproducibility notes (#36)"
```

---

## Task 9: Operational runbook (post-merge — NOT code; run manually after PR merges)

> Execute these in order **only after** the PR from Tasks 1–8 is merged to `main`. Each is operator-confirmed; the purge is irreversible.

- [ ] **Step 1: Rebuild every image fresh**

Run: `gh workflow run build.yml -f image=all` then watch: `gh run watch "$(gh run list --workflow=build.yml -L1 --json databaseId -q '.[0].databaseId')"`
Expected: all matrix builds succeed; new digests pushed and tagged.

- [ ] **Step 2: Verify a sample (multi-arch + attestation)**

Run:
```bash
skopeo inspect --raw docker://ghcr.io/nq-rdl/bun-ubi9:latest | jq '.mediaType, [.manifests[].platform]'
bash scripts/verify-image.sh ghcr.io/nq-rdl/bun-ubi9:latest
```
Expected: an OCI index with linux/amd64 + linux/arm64; `gh attestation verify` passes.

- [ ] **Step 3: Purge dry-run; review every line**

Run: `bash scripts/ghcr-purge.sh`
Expected: every current tag + its children are `KEEP`; only stale untagged orphans are `DELETE`. **Stop and read the output.**

- [ ] **Step 4: Apply the purge (irreversible — operator confirms)**

Run: `bash scripts/ghcr-purge.sh --apply`
Expected: prints `Deleted N version(s)`. Re-run the dry-run; expect `Would delete 0`.

- [ ] **Step 5: Close issue #36 and its PR as superseded**

Run:
```bash
gh issue comment 36 --body "Superseded by the root-cause fix (digest-pinned bases + commit-driven rebuilds + FROM-aware drift-checker). Orphan generation is stopped at the source, so a scheduled cleanup janitor is no longer needed. The accumulated backlog was cleared once via scripts/ghcr-purge.sh (reachability-safe)."
gh issue close 36
```
Then close the issue-36 PR with a comment pointing to this work.

---

## Self-review notes

- **Spec coverage:** §4.1 digest-pin → Task 1; §4.2 drop schedule + alias scope → Tasks 2,3; §4.3 rescan all tags → Task 4; §4.4 drift-checker + dependabot trim → Task 5; §4.5 purge → Task 7 + Task 9; §4.6 close #36 → Task 9; §4.7 tests (static + validate-base-pins + drift self-validate) → Tasks 1,2,5,6; §4.8 docs → Task 8. All covered.
- **Hardening (user-selected):** scan all tags → Task 4; rollback doc → Task 8. Deferred (auto-merge, auto-issue) intentionally absent.
- **No placeholders:** digests are real (write-time resolved); every code step is complete.
- **CI safety:** new scripts are shellcheck-targeted (Task 7 Step 2); new workflows are actionlint-checked each task; `base_image.rego` final-FROM rule remains satisfied (Task 1 Step 7).
