# jamovi-on-UBI9 image chain — design

**Date:** 2026-06-09
**Branch:** `feat/jamovi-ubi9-stack`
**Status:** approved (scope confirmed via brainstorming) — implementation in progress

## Goal

Rebuild the [jamovi](https://github.com/jamovi/jamovi) statistics application's container
stack on Red Hat **UBI9** so it can be deployed under this catalog's policy + scanning +
attestation guarantees, instead of jamovi's upstream Ubuntu 24.04 ("noble") images.

The user also asked whether "rstudio also needs to be built." It does — but *rstudio* here
means [`rstudio/r-base`](https://github.com/rstudio/r-docker) (now `posit/r-base`): the **R
runtime** built from Posit's prebuilt R binaries, **not** the RStudio Server IDE. jamovi's
`deps-Dockerfile` starts `FROM rstudio/r-base:4.5.0-noble`, so an R-on-UBI9 base is the
foundation of the whole stack. No separate IDE image is in scope.

## Upstream chain we are mirroring

| Upstream | Role |
|---|---|
| `rstudio/r-base:4.5.0-noble` | R 4.5.0 runtime (Posit binaries), base for everything |
| `jamovi/jamovi-deps:2.7.11` | `FROM r-base` + ~200 CRAN packages + system libs |
| `jamovi/jamovi:2.7.x` | `FROM jamovi-deps`, multi-stage build of server/client/engine/modules |

## Images we build (UBI9)

A three-link chain mirroring the existing `datascience` bake chain
(`docker-stacks-foundation` → `base-notebook` → …):

| Image | FROM | Contents |
|---|---|---|
| `r-base-ubi9` | `registry.access.redhat.com/ubi9/ubi:9.8` (digest-pinned) | Posit R **4.5.0** via the `rhel-9` RPM → `/opt/R/4.5.0`; fontconfig, locale, pandoc. The reusable R foundation. |
| `jamovi-deps-ubi9` | `${BASE_CONTAINER}` → `r-base-ubi9` | ~200 CRAN packages (the two `install.packages` blocks) + system libs (apt→dnf) + `jmvReadWrite` from GitHub. |
| `jamovi-ubi9` | `${BASE_CONTAINER}` → `jamovi-deps-ubi9` | Multi-stage: server (Cython/py3.12), client (node/vite), engine (C++), jmvcore + jmv/plots modules, i18n → assembled runtime. Exposes 41337, runs `/usr/bin/python3.12 -m jamovi.server 41337 --if=*`. |

## Pins (resolved & verified 2026-06-09)

- **UBI9 base:** `registry.access.redhat.com/ubi9/ubi:9.8@sha256:46d19c10caf9888e8a01131283eaaf50c7f5d4eddab02cd92a66f8adf2e15407` — confirmed multi-arch index covering linux/amd64.
- **R:** 4.5.0, `OS_IDENTIFIER=rhel-9`, RPM `https://cdn.posit.co/r/rhel-9/pkgs/R-4.5.0-1-1.x86_64.rpm` (HTTP 200), installs to `/opt/R/4.5.0`. Matches jamovi's hard-coded `R_HOME=/opt/R/4.5.0/lib/R`.
- **jamovi:** tag `v2.7.30` → commit `771860de06a6732712043ee9a2a5c86a53a66985` (pin by commit, not tag).
- **jamovi submodules** (recursive clone required): `jmv` (jamovi/jmv), `readstat` (jamovi/jamovi-readstat — note: `readstat` is a **submodule**, not a plain dir), `i18n` (jamovi/jamovi-i18n), `plots` (jamovi/jmvplots).

## Build orchestration — extend `docker-bake.hcl`

The three images chain on each other, so a single CI run must build them in order without a
registry round-trip between links. That is exactly what the existing bake pattern does:
in-graph `contexts` + `args` wiring resolves each `FROM ${BASE_CONTAINER}` to the
just-built target.

- New bake **group** `jamovi` with targets `r-base`, `jamovi-deps`, `jamovi`.
- New **bake job** in `build.yml` (parallel to the datascience one): bake → Trivy CRITICAL/HIGH (fixable, `ignore-unfixed`) scan each image + SARIF upload → publish convenience aliases (`r-base`, `jamovi-deps`, `jamovi`).
- Each `image.yaml` declares `bake_target:` so the standalone `build` matrix correctly **excludes** these (the `discover` job skips `bake_target` images).

## Sourcing the jamovi tree (layer 3 build context)

The jamovi Dockerfile's build context is the repo root and it COPYs `server/ client/ engine/
jmvcore/ jmv/ plots/ i18n/ jamovi-compiler/ readstat/ platform/ version`. Because `jmv`,
`readstat`, `i18n`, `plots` are **git submodules**, the source must be fetched recursively.

**Chosen approach — build-time pinned clone in a `source` stage:**

```dockerfile
FROM ${BASE_CONTAINER} AS source
ARG JAMOVI_REF=771860de06a6732712043ee9a2a5c86a53a66985
RUN git clone https://github.com/jamovi/jamovi.git /src \
 && git -C /src checkout ${JAMOVI_REF} \
 && git -C /src submodule update --init --recursive
```

Downstream stages `COPY --from=source /src/<subdir> …`. Rationale: pins by commit SHA
(reproducible, content-addressed), keeps `images/jamovi-ubi9/` self-contained, and needs
**zero** changes to the checkout/bake/smoke workflows — unlike a submodule, which would force
`submodules: recursive` everywhere. (Network-at-build is already an accepted pattern in this
repo, e.g. `bun-ubi9` downloads + checksums a release tarball.)

## The UBI repo-subset problem and the AlmaLinux+EPEL decision (resolved)

**Discovered during implementation (empirically, in a real UBI9 container):** UBI9's
repositories are a deliberately restricted subset of RHEL9. Three things the stack needs are
**absent from every UBI repo** (BaseOS/AppStream/CodeReady/EPEL):

- `flexiblas-devel` — a **hard RPM dependency of Posit's R RPM** (so even `r-base` won't install
  R on pure UBI),
- `protobuf` / `protobuf-devel` / `protobuf-compiler` (RProtoBuf + the C++ engine),
- all `boost*` (the C++ engine + the Cython core link `boost_filesystem`/`boost_system`).

The verification agents had reported these as "present" because they checked *full* CentOS
Stream 9 / RHEL9 (pkgs.org) — not the UBI subset. Resolution (user-approved supply-chain
decision): enable **EPEL 9** (nanomsg, glpk, libRmath) and **AlmaLinux 9** BaseOS/AppStream/CRB
(flexiblas-devel, protobuf, boost) at **`priority=200`**, so UBI/Red Hat packages always win and
AlmaLinux only fills genuine gaps. Both GPG keys are pre-imported. Validated end-to-end: R 4.5.0
installs, and RProtoBuf/igraph/systemfonts build+load against these libs.

## Other UBI9 porting hot-spots (all handled)

- **Python 3.12:** UBI9's `/usr/bin/python3` is 3.9 → install `python3.12` explicitly; CMD calls
  `/usr/bin/python3.12`. **Path divergence:** Debian uses `dist-packages`, RHEL uses
  `site-packages`. Empirically, root `pip --break-system-packages` lands pure-Python packages in
  `/usr/local/lib/python3.12/site-packages` (purelib) **and compiled C-extensions in
  `/usr/local/lib64/python3.12/site-packages` (platlib)** — the final stage COPYs **both** trees
  (a review-caught blocker: copying only `lib` would drop numpy/scipy/lxml/aiohttp/nanomsg).
- **protobuf:** el9 protobuf is frozen at 3.14. The C++ engine uses system protoc 3.14
  (ABI-matched to `-lprotobuf`); the Python `--python_out` step uses a pinned **protoc 34.0**
  (matching `protobuf==7.34.0`), since `setup.py`'s protoc is python-only. The engine and server
  are separate stages, so the two protoc versions never collide. Because we *recompile* engine +
  Cython on UBI9, all native ABIs (ICU 67, protobuf 3.14, boost 1.75) are self-consistent.
- **nanomsg:** EPEL (`nanomsg-devel` to build the binding/engine, `nanomsg` runtime); `boost::asio`
  from `boost-devel` (no standalone asio). node 22.16.0 tarball portable as-is.

## Policy / scanning / supply-chain wiring

- Final stage of every image written as `FROM ${BASE_CONTAINER}` (or a UBI base) so
  `base_image.rego` (which checks only the **last** FROM) passes — jamovi's upstream final
  stage `FROM r-base AS jamovi` (internal alias) would otherwise be denied.
- 5 required OCI labels on each final image; `org.opencontainers.image.vendor="Research Data
  Laboratory"`; `licenses`: `AGPL-3.0-or-later` (jamovi) / `GPL-2.0-or-later` (r-base +
  jamovi-deps) per upstream.
- `image.yaml` tags pass `image-meta/tags.rego` (X.Y.Z / X.Y / latest).
- Chained `ARG BASE_CONTAINER=…@sha256:<placeholder>` digests: pass the format test
  (`test-chained-bases-pinned.sh`) and **bootstrap-skip** the reachability test
  (`test-chained-bases-reachable.sh`: unpublished tag → SKIP). After the chain's first CI
  publish, a follow-up "repin" PR sets real digests — the same flow as the in-flight
  `fix/scipy-repin-base-digest`.
- Trivy CRITICAL/HIGH scan per image + SARIF upload (in the bake job).
- `.github/dependabot.yml`: 3 new `docker` ecosystem entries.
- A `changie` fragment (`Added`).

## Versioning & tags

Per-service semver (more meaningful than the datascience calendar tag; satisfies the tag
policy):

- `r-base-ubi9`: `4.5.0`, `4.5`, `latest`
- `jamovi-deps-ubi9`: `2.7.30`, `2.7`, `latest`
- `jamovi-ubi9`: `2.7.30`, `2.7`, `latest`

The bake job tags each target explicitly and publishes the matching `-ubi`-stripped aliases.

## Verification strategy (honest scope)

- `r-base-ubi9`: buildable + smoke-testable **locally** (R installs from an RPM, minutes).
- `jamovi-deps-ubi9` (≈200 R packages compiled from source) and `jamovi-ubi9`
  (C++/Cython/vite): **multi-hour builds, infeasible in this environment.** Validated
  **statically** here (hadolint, conftest/OPA policy, YAML, shellcheck, bake config parse,
  chained-pin tests) and built/scanned by **CI on the PR**. Expect 1–2 iterations on the
  layer-3 port (protobuf/python3.12/nanomsg). The PR description states this explicitly.
- Local smoke/trivy pre-push hooks build *every* image; for the heavy chain that is
  impractical, so pushes on this branch use `SKIP_SMOKE=1` / `SKIP_TRIVY=1` (documented
  bypass), relying on CI.

## Out of scope

- RStudio Server IDE image.
- Multi-arch (arm64) jamovi builds — declared `linux/amd64` only.
- A Kubernetes deployment manifest for jamovi (the 3-origin `JAMOVI_HOST_A/B/C` security model
  is documented in the image README; manifests are a downstream concern).
