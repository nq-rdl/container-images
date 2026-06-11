# TAG/MINOR must stay in sync with each image.yaml's tags and build.yml's bake-job env.
variable "REGISTRY" { default = "ghcr.io/nq-rdl" }
variable "TAG"      { default = "2026.6.0" }
variable "MINOR"    { default = "2026.6" }

# jamovi chain versions — keep in sync with the image.yaml tags and build.yml's jamovi bake job.
variable "R_VERSION"      { default = "4.5.0" }
variable "R_MINOR"        { default = "4.5" }
variable "JAMOVI_VERSION" { default = "2.7.30" }
variable "JAMOVI_MINOR"   { default = "2.7" }

# "all" is the canonical target for local smoke-tests and scripts that must bake every chain.
# When a new bake chain is added, add its group name here so scripts that bake "all" pick it up
# automatically — do NOT hardcode individual group names in scripts/smoke-test.sh or
# scripts/trivy-scan.sh.
group "all" {
  targets = ["datascience", "jamovi"]
}

group "datascience" {
  targets = ["foundation", "base-notebook", "minimal-notebook", "scipy-notebook"]
}

target "foundation" {
  context    = "images/docker-stacks-foundation-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  tags = [
    "${REGISTRY}/docker-stacks-foundation-ubi9:${TAG}",
    "${REGISTRY}/docker-stacks-foundation-ubi9:${MINOR}",
    "${REGISTRY}/docker-stacks-foundation-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=docker-stacks-foundation-ubi9"]
  cache-to   = ["type=gha,scope=docker-stacks-foundation-ubi9,mode=max"]
}

target "base-notebook" {
  context    = "images/base-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  # In-graph build: resolve FROM ${BASE_CONTAINER} to the just-built foundation target
  # instead of pulling from the registry. Both args + contexts are required together.
  contexts = {
    "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9" = "target:foundation"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/docker-stacks-foundation-ubi9"
  }
  tags = [
    "${REGISTRY}/base-notebook-ubi9:${TAG}",
    "${REGISTRY}/base-notebook-ubi9:${MINOR}",
    "${REGISTRY}/base-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=base-notebook-ubi9"]
  cache-to   = ["type=gha,scope=base-notebook-ubi9,mode=max"]
}

target "minimal-notebook" {
  context    = "images/minimal-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = {
    "ghcr.io/nq-rdl/base-notebook-ubi9" = "target:base-notebook"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/base-notebook-ubi9"
  }
  tags = [
    "${REGISTRY}/minimal-notebook-ubi9:${TAG}",
    "${REGISTRY}/minimal-notebook-ubi9:${MINOR}",
    "${REGISTRY}/minimal-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=minimal-notebook-ubi9"]
  cache-to   = ["type=gha,scope=minimal-notebook-ubi9,mode=max"]
}

target "scipy-notebook" {
  context    = "images/scipy-notebook-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = {
    "ghcr.io/nq-rdl/minimal-notebook-ubi9" = "target:minimal-notebook"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/minimal-notebook-ubi9"
  }
  tags = [
    "${REGISTRY}/scipy-notebook-ubi9:${TAG}",
    "${REGISTRY}/scipy-notebook-ubi9:${MINOR}",
    "${REGISTRY}/scipy-notebook-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=scipy-notebook-ubi9"]
  cache-to   = ["type=gha,scope=scipy-notebook-ubi9,mode=max"]
}

# jamovi chain: r-base-ubi9 -> jamovi-deps-ubi9 -> jamovi-ubi9. In-graph `contexts` + `args`
# resolve each FROM ${BASE_CONTAINER} to the just-built target (no registry round-trip mid-chain),
# the same pattern as the datascience chain above.
group "jamovi" {
  targets = ["r-base", "jamovi-deps", "jamovi"]
}

target "r-base" {
  context    = "images/r-base-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  tags = [
    "${REGISTRY}/r-base-ubi9:${R_VERSION}",
    "${REGISTRY}/r-base-ubi9:${R_MINOR}",
    "${REGISTRY}/r-base-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=r-base-ubi9"]
  cache-to   = ["type=gha,scope=r-base-ubi9,mode=max"]
}

target "jamovi-deps" {
  context    = "images/jamovi-deps-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = {
    "ghcr.io/nq-rdl/r-base-ubi9" = "target:r-base"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/r-base-ubi9"
  }
  tags = [
    "${REGISTRY}/jamovi-deps-ubi9:${JAMOVI_VERSION}",
    "${REGISTRY}/jamovi-deps-ubi9:${JAMOVI_MINOR}",
    "${REGISTRY}/jamovi-deps-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=jamovi-deps-ubi9"]
  cache-to   = ["type=gha,scope=jamovi-deps-ubi9,mode=max"]
}

target "jamovi" {
  context    = "images/jamovi-ubi9"
  dockerfile = "Containerfile"
  platforms  = ["linux/amd64"]
  contexts = {
    "ghcr.io/nq-rdl/jamovi-deps-ubi9" = "target:jamovi-deps"
  }
  args = {
    BASE_CONTAINER = "ghcr.io/nq-rdl/jamovi-deps-ubi9"
    # Pass R_VERSION so the server stage derives JAMOVI_R_VERSION automatically;
    # bumping R_VERSION here propagates to env.conf without any Containerfile edit.
    R_VERSION = R_VERSION
  }
  tags = [
    "${REGISTRY}/jamovi-ubi9:${JAMOVI_VERSION}",
    "${REGISTRY}/jamovi-ubi9:${JAMOVI_MINOR}",
    "${REGISTRY}/jamovi-ubi9:latest",
  ]
  cache-from = ["type=gha,scope=jamovi-ubi9"]
  cache-to   = ["type=gha,scope=jamovi-ubi9,mode=max"]
}
