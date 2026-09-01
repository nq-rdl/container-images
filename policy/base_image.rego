package main

import data.helpers

# Documented non-UBI vendor bases.
#
# CONTRIBUTING.md states the UBI-base rule as absolute, and it is: an entry here is not a
# way around the rule, it is a reviewed, tracked exception for an image that has no UBI
# equivalent yet. Every entry must name the image it covers and a tracking issue for its
# migration, and the entry is deleted the moment that migration lands. An addition to this
# set is a policy change and should be reviewed as one.
#
# Matching is on the repository part only, so a waiver holds however the image is
# pinned: bare, ":tag", "@sha256:...", or ":tag@sha256:...". Pinning is a separate
# concern, enforced independently by tests/test-base-images-pinned.sh — this rule must
# not double as a pin check, or the stricter digest-only form would be rejected while
# the looser tagged form passed.
#
# The match is anchored on a full repository name: either the whole reference, or the
# repository followed by a ":" or "@" delimiter. That stops a look-alike repository
# (quay.io/jupyter/datascience-notebook-fork) from inheriting a waiver granted to a
# repository whose name is a prefix of its own. Comparing against the delimiters rather
# than splitting on ":" also keeps a registry port (host:5000/repo) from being mistaken
# for a tag.
#
#   quay.io/jupyter/datascience-notebook -> images/datascience-notebook-cuda
#     Upstream Jupyter CUDA stack; no UBI-based equivalent is published. Added in #71,
#     which also carries a matching hadolint DL3026 waiver. Migration tracked in #84.
non_ubi_base_exceptions := {"quay.io/jupyter/datascience-notebook"}

excepted_base(val) if {
	some repo in non_ubi_base_exceptions
	val == repo
}

excepted_base(val) if {
	some repo in non_ubi_base_exceptions
	some delim in {":", "@"}
	startswith(val, concat("", [repo, delim]))
}

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
	not excepted_base(val)
	msg := sprintf("Final FROM must use a UBI base or a UBI-rooted ghcr.io/nq-rdl/ base, got: %s", [val])
}
