# scipy-notebook Repin + Chained-Base Reachability Guard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile issue #45 by repinning `scipy-notebook-ubi9`'s placeholder chained-base digest to the published GHCR digest, driven by a new TDD reachability guard that also runs in CI.

**Architecture:** A shared bash test (`tests/test-chained-bases-reachable.sh`) uses `crane` to assert each `ARG BASE_CONTAINER=` chained pin's digest actually resolves in GHCR and its image index covers the platforms declared in `image.yaml`. It is exposed as an opt-in pixi task (kept out of the default offline `policy-check`) and wired into `validate-base-pins.yml`. The test is RED against the current placeholder and GREEN after the repin.

**Tech Stack:** bash, crane (conda-forge / `imjasonh/setup-crane`), jq, pixi tasks in `pyproject.toml`, GitHub Actions, changie.

**Branch:** `fix/scipy-repin-base-digest` (already cut from `origin/main` @ `9817207`).

**Authoritative digest:** `sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184`
**Placeholder being replaced:** `sha256:640ebba9ab2959fd6489f0b0e30b0434bfa5b3308b9e478ee766e1546e448834`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `pyproject.toml` | Modify | Add `crane` + `jq` pixi deps; add `policy-check-chained-bases-reachable` task (NOT in default `policy-check`). |
| `tests/test-chained-bases-reachable.sh` | Create | The reachability + platform-coverage guard (shared by local + CI). |
| `images/scipy-notebook-ubi9/Containerfile` | Modify | Repin line 14 digest; refresh the comment block. |
| `.github/workflows/validate-base-pins.yml` | Modify | Run the guard in CI; extend `paths:` filters. |
| `.changes/unreleased/Fixed-<ts>.yaml` | Create | Changelog fragment. |

---

## Task 1: Tooling — add `crane` + `jq` deps and the opt-in pixi task

**Files:**
- Modify: `pyproject.toml` (`[tool.pixi.dependencies]` and `[tool.pixi.tasks]`)

- [ ] **Step 1: Add `crane` and `jq` to pixi dependencies**

In `pyproject.toml`, change the `[tool.pixi.dependencies]` block from:

```toml
[tool.pixi.dependencies]
python = ">=3.10"
shellcheck = "*"
actionlint = "*"
conftest = "*"
trivy = "*"
pre-commit = "*"
zensical = ">=0.0.43,<0.0.44"
```

to:

```toml
[tool.pixi.dependencies]
python = ">=3.10"
shellcheck = "*"
actionlint = "*"
conftest = "*"
trivy = "*"
pre-commit = "*"
zensical = ">=0.0.43,<0.0.44"
crane = "*"
jq = "*"
```

- [ ] **Step 2: Add the opt-in task (NOT in default `policy-check`)**

In `[tool.pixi.tasks]`, immediately after the line:

```toml
policy-check-chained-bases = "bash tests/test-chained-bases-pinned.sh"
```

add:

```toml
policy-check-chained-bases-reachable = "bash tests/test-chained-bases-reachable.sh"
```

Do **not** add it to the `[tool.pixi.tasks.policy-check] depends-on` list — the default policy-check must stay offline/hermetic.

- [ ] **Step 3: Install and verify tooling is available**

Run: `pixi install && pixi run -- crane version && pixi run -- jq --version`
Expected: pixi resolves/installs; `crane` prints a version line; `jq` prints e.g. `jq-1.7.x`.

- [ ] **Step 4: Verify the task is registered**

Run: `pixi task list 2>&1 | grep policy-check-chained-bases-reachable`
Expected: the task name appears.

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml pixi.lock
git commit -m "build(pixi): add crane + jq deps and policy-check-chained-bases-reachable task (#45)"
```

(If `pixi install` did not change `pixi.lock`, omit it from the `git add`.)

---

## Task 2: Write the reachability guard and confirm RED

**Files:**
- Create: `tests/test-chained-bases-reachable.sh`

- [ ] **Step 1: Create the test script (complete contents)**

Create `tests/test-chained-bases-reachable.sh` with exactly:

```bash
#!/usr/bin/env bash
# Asserts every `ARG BASE_CONTAINER=` chained base in images/*/Containerfile is a LIVE
# pin: its pinned @sha256 digest resolves in GHCR AND the resolved image index covers
# the platforms declared in the sibling image.yaml.
#
# Why this exists: tests/test-chained-bases-pinned.sh validates only the digest *format*
# (a placeholder digest passes that regex). This test catches placeholder/stale digests
# that do not actually exist in the registry — the failure mode a standalone
# `docker build` hits as `manifest unknown`.
#
# Tooling: crane (declared in pyproject.toml [tool.pixi.dependencies]; CI installs it via
# imjasonh/setup-crane) and jq. Platforms are parsed from image.yaml with awk to avoid a
# yq-flavour dependency; image.yaml uses a simple top-level `platforms:` block list.
#
# Error-class-specific semantics (so the bootstrap skip cannot mask real failures):
#   * tag not published yet (404 / MANIFEST_UNKNOWN / NAME_UNKNOWN) -> SKIP (bootstrap)
#   * tag exists but pinned digest unreachable                      -> FAIL (placeholder/stale)
#   * any other crane error (auth / rate-limit / network)           -> FAIL (fail-closed)
#   * crane absent entirely (offline dev)                           -> SKIP loudly, exit 0
set -euo pipefail

FAILURES=0
SKIPS=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }

if ! command -v crane >/dev/null 2>&1; then
  echo "SKIP: 'crane' not on PATH — chained-base reachability not verified."
  echo "      run 'pixi install' (crane is a declared dependency) or use the CI job."
  exit 0
fi

# Does a crane error blob indicate an absent tag/repo (vs auth/network/other)?
is_absent_error() {
  grep -qiE 'MANIFEST_UNKNOWN|NAME_UNKNOWN|not found|status code 404|: 404' <<<"$1"
}

# Read a simple top-level `platforms:` block list from an image.yaml (no yq dependency).
read_platforms() {
  awk '
    /^platforms:[[:space:]]*$/ { inblk=1; next }
    inblk && /^[^[:space:]#]/  { inblk=0 }
    inblk && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["[:space:]]/, "")
      if ($0 != "") print
    }
  ' "$1"
}

shopt -s nullglob
for cf in images/*/Containerfile; do
  grep -qE '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER' "$cf" || continue

  val=$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=' "$cf" | tail -1 \
        | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_CONTAINER=//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//')
  if [[ "$val" != *"@sha256:"* ]]; then
    fail "$cf: BASE_CONTAINER='$val' is not digest-pinned"; continue
  fi

  repo_tag="${val%@*}"             # ghcr.io/nq-rdl/<img>:<tag>
  digest="${val##*@}"              # sha256:<hex>
  repo="${repo_tag%:*}"            # ghcr.io/nq-rdl/<img>
  digest_ref="${repo}@${digest}"   # crane rejects repo:tag@digest; address by repo@digest

  dir=$(dirname "$cf"); yaml="${dir}/image.yaml"
  WANT=()
  [ -f "$yaml" ] && mapfile -t WANT < <(read_platforms "$yaml")
  [ "${#WANT[@]}" -gt 0 ] || WANT=("linux/amd64")

  # 1) Tag existence probe (bootstrap detection). Capture stderr only.
  if ! err=$(crane manifest "$repo_tag" 2>&1 >/dev/null); then
    if is_absent_error "$err"; then
      skip "$cf: ${repo_tag} not published yet (bootstrap) — reachability deferred"; continue
    fi
    fail "$cf: querying ${repo_tag} failed: ${err}"; continue
  fi

  # 2) Pinned-digest reachability (placeholder/stale detection).
  if ! mfst=$(crane manifest "$digest_ref" 2>&1); then
    fail "$cf: pinned digest ${digest} unreachable in ${repo} (placeholder/stale): ${mfst}"; continue
  fi

  # 3) Platform coverage: must be a non-empty image index covering every WANT platform.
  if ! have=$(jq -er '
        if (.manifests | type) == "array" and (.manifests | length) > 0
        then [.manifests[].platform | "\(.os)/\(.architecture)"] | join(" ")
        else error("not a non-empty image index") end' <<<"$mfst" 2>/dev/null); then
    fail "$cf: ${digest_ref} is not a non-empty image index"; continue
  fi
  miss=0
  for p in "${WANT[@]}"; do
    grep -qw "$p" <<<"$have" || { fail "$cf: ${digest_ref} missing ${p} (has: ${have})"; miss=1; }
  done
  [ "$miss" -eq 0 ] && pass "$cf: ${digest_ref} resolves and covers ${WANT[*]}"
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} chained base(s) FAILED reachability/platform check (${SKIPS} skipped)"
  exit 1
fi
echo "All chained bases reachable and platform-covered (${SKIPS} skipped)"
exit 0
```

- [ ] **Step 2: Make it executable and lint it**

```bash
chmod +x tests/test-chained-bases-reachable.sh
pixi run shellcheck tests/test-chained-bases-reachable.sh
```
Expected: shellcheck exits 0 with no output.

- [ ] **Step 3: Run the test — verify it FAILS (RED) for the right reason**

Run: `pixi run policy-check-chained-bases-reachable`
Expected: exit code 1, with a line resembling:
```
FAIL: images/scipy-notebook-ubi9/Containerfile: pinned digest sha256:640ebba9ab2959fd6489f0b0e30b0434bfa5b3308b9e478ee766e1546e448834 unreachable in ghcr.io/nq-rdl/minimal-notebook-ubi9 (placeholder/stale): ...manifest unknown...
1 chained base(s) FAILED reachability/platform check (0 skipped)
```
The FAIL must be the *unreachable pinned digest* (not a SKIP and not a tag-query failure). If it SKIPs instead, the absent-error classifier is too broad — confirm `crane manifest ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0` succeeds (tag exists) before continuing.

- [ ] **Step 4: Commit the (intentionally red) guard**

```bash
git add tests/test-chained-bases-reachable.sh
git commit -m "test(scipy-notebook-ubi9): add chained-base GHCR reachability guard (RED) (#45)"
```
Note: no pre-commit hook runs this test, so the red state will not block the commit. The branch is not pushed until Task 6.

---

## Task 3: Repin the Containerfile and confirm GREEN

**Files:**
- Modify: `images/scipy-notebook-ubi9/Containerfile` (lines 10–14)

- [ ] **Step 1: Refresh the comment block (lines 10–13)**

Replace these four comment lines:

```dockerfile
# ARG BASE_CONTAINER default: placeholder digest from the locally-built minimal-notebook image.
# In bake builds the `contexts` + `args` wiring in docker-bake.hcl overrides this to use the
# in-graph minimal-notebook target, so the digest below is never pulled from a registry.
# Replace with the pushed ghcr.io/nq-rdl/minimal-notebook-ubi9 digest after it is published.
```

with:

```dockerfile
# ARG BASE_CONTAINER default: digest of the published ghcr.io/nq-rdl/minimal-notebook-ubi9.
# In bake builds the `contexts` + `args` wiring in docker-bake.hcl overrides this to use the
# in-graph minimal-notebook target, so the digest below is never pulled from a registry — it
# is used only by a standalone `docker build images/scipy-notebook-ubi9`. Reachability of this
# pin is guarded by tests/test-chained-bases-reachable.sh.
```

- [ ] **Step 2: Repin the digest (line 14)**

Replace:

```dockerfile
ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:640ebba9ab2959fd6489f0b0e30b0434bfa5b3308b9e478ee766e1546e448834
```

with:

```dockerfile
ARG BASE_CONTAINER=ghcr.io/nq-rdl/minimal-notebook-ubi9:2026.6.0@sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184
```

- [ ] **Step 3: Verify the exact acceptance digest is present (#45 criterion)**

Run: `grep -n 'sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184' images/scipy-notebook-ubi9/Containerfile`
Expected: one match on line 14. Also confirm the placeholder is gone:
`! grep -q '640ebba9' images/scipy-notebook-ubi9/Containerfile && echo "placeholder removed"`
Expected: `placeholder removed`.

- [ ] **Step 4: Run the guard — verify it PASSES (GREEN)**

Run: `pixi run policy-check-chained-bases-reachable`
Expected: exit code 0, with:
```
PASS: images/scipy-notebook-ubi9/Containerfile: ghcr.io/nq-rdl/minimal-notebook-ubi9@sha256:46e14db9663ef49c9f3fa62ff7b57d06358f41878ca53ba899adac941a1e2184 resolves and covers linux/amd64
All chained bases reachable and platform-covered (0 skipped)
```

- [ ] **Step 5: Verify no regression in the offline policy-check**

Run: `pixi run policy-check`
Expected: all five sub-checks pass (the format-only `policy-check-chained-bases` still passes; the repin did not break it).

- [ ] **Step 6: Commit**

```bash
git add images/scipy-notebook-ubi9/Containerfile
git commit -m "fix(scipy-notebook-ubi9): repin BASE_CONTAINER to published minimal-notebook digest (#45)"
```
(Pre-commit runs hadolint + conftest on the Containerfile; both should pass — the `# hadolint ignore=DL3026` directive is unchanged.)

---

## Task 4: Wire the guard into CI

**Files:**
- Modify: `.github/workflows/validate-base-pins.yml` (`on:` paths + new step)

- [ ] **Step 1: Extend the `paths:` filters**

Replace:

```yaml
on:
  pull_request:
    paths: ['images/**', '.github/workflows/validate-base-pins.yml']
  push:
    branches: [main]
    paths: ['images/**']
```

with:

```yaml
on:
  pull_request:
    paths: ['images/**', 'tests/**', 'pyproject.toml', '.github/workflows/validate-base-pins.yml']
  push:
    branches: [main]
    paths: ['images/**', 'tests/**', 'pyproject.toml']
```

- [ ] **Step 2: Add the reachability step**

At the end of the `validate.steps:` list (after the existing "Assert each pinned base is an index covering declared platforms" step), append:

```yaml
      - name: Assert chained ARG BASE_CONTAINER pins resolve and cover declared platforms
        run: bash tests/test-chained-bases-reachable.sh
```

(`crane` is already on PATH via `imjasonh/setup-crane`; `jq` and `awk` are preinstalled on `ubuntu-latest`.)

- [ ] **Step 3: Lint the workflow**

Run: `pixi run actionlint .github/workflows/validate-base-pins.yml`
Expected: exit 0, no findings.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/validate-base-pins.yml
git commit -m "ci(validate-base-pins): run chained-base reachability guard on PR + main (#45)"
```

---

## Task 5: Changelog fragment

**Files:**
- Create: `.changes/unreleased/Fixed-<timestamp>.yaml`

- [ ] **Step 1: Create the fragment**

```bash
TS=$(date -u +%Y%m%d-%H%M%S)
ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000000+00:00)
cat > ".changes/unreleased/Fixed-${TS}.yaml" <<EOF
kind: Fixed
body: Repin scipy-notebook-ubi9 BASE_CONTAINER to the published minimal-notebook-ubi9 digest, and add a crane-based guard (local pixi task + validate-base-pins CI) asserting chained base pins resolve in GHCR and cover declared platforms.
time: ${ISO}
EOF
cat ".changes/unreleased/Fixed-${TS}.yaml"
```
Expected: a valid YAML fragment with `kind: Fixed`.

- [ ] **Step 2: Commit**

```bash
git add .changes/unreleased/
git commit -m "docs(changelog): Fixed fragment for #45 repin + reachability guard"
```

---

## Task 6: Final verification (no push)

- [ ] **Step 1: Run the full local gate**

```bash
pixi run lint-shell
pixi run lint-actions
pixi run policy-check
pixi run policy-check-chained-bases-reachable
```
Expected: all pass (exit 0).

- [ ] **Step 2: (Optional, heavy) standalone build proof**

Only if a full local build is desired (pulls the real base; many layers):
```bash
docker build -t scipy-repin-check images/scipy-notebook-ubi9
```
Expected: the base now pulls (no `manifest unknown`); build proceeds. Skip if relying on the reachability guard + CI.

- [ ] **Step 3: Review the commit series**

Run: `git log --oneline origin/main..HEAD`
Expected: the design-spec commit plus Tasks 1–5 commits, in order.

- [ ] **Step 4: STOP — hand back for review/push**

Do **not** push. Pushing triggers pre-push hooks (`smoke-test.sh` full build + k3d, `trivy-scan.sh`). Surface the branch state and let the user decide on `requesting-code-review` → push → PR (the PR should reference "Closes #45").

---

## Self-Review (against the spec)

- **Spec coverage:** repin → Task 3; reachability+platform test → Task 2; crane dep + opt-in task in pyproject.toml (excluded from default policy-check) → Task 1; CI wiring + path filters → Task 4; changie fragment → Task 5; one-off exact-digest acceptance → Task 3 Step 3; RED→GREEN evidence → Task 2 Step 3 / Task 3 Step 4. ✓ All covered.
- **Placeholder scan:** none — full script, exact edits, exact commands and expected outputs throughout. ✓
- **Type/name consistency:** task name `policy-check-chained-bases-reachable`, script path `tests/test-chained-bases-reachable.sh`, and digest `sha256:46e14db966…` are identical across Tasks 1–6. ✓
- **Tooling consistency:** script depends only on crane + jq + awk/grep/sed; crane+jq declared in Task 1; CI provides crane (setup-crane) + jq/awk (preinstalled). No yq dependency. ✓
