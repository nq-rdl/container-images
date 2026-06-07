# TAG/MINOR must stay in sync with each image.yaml's tags and build.yml's bake-job env.
variable "REGISTRY" { default = "ghcr.io/nq-rdl" }
variable "TAG"      { default = "2026.6.0" }
variable "MINOR"    { default = "2026.6" }

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
