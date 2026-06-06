package main

import data.helpers

# Repo-internal images under ghcr.io/nq-rdl/ are UBI-rooted by construction: every image
# must pass this policy before it is pushed to GHCR, so a chained FROM is transitively
# UBI-rooted. The chain is written as `ARG BASE_CONTAINER=ghcr.io/nq-rdl/...@sha256:...`
# + `FROM ${BASE_CONTAINER}`; the ARG default's digest pin is enforced by
# tests/test-chained-bases-pinned.sh.
deny contains msg if {
	idx := helpers.final_stage_start
	val := input[idx].Value[0]
	not startswith(val, "registry.access.redhat.com/ubi")
	not startswith(val, "registry.redhat.io/ubi")
	not startswith(val, "ghcr.io/nq-rdl/")
	val != "${BASE_CONTAINER}"
	msg := sprintf("Final FROM must use a UBI base or a UBI-rooted ghcr.io/nq-rdl/ base, got: %s", [val])
}
