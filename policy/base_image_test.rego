package main

# conftest aggregates EVERY `deny` in package main (base_image.rego AND labels.rego), so we
# isolate the rule under test by filtering to its message ("Final FROM"). This keeps the tests
# independent of labels.rego (which would otherwise deny these label-less fixtures).

# A chained child: final FROM is the ${BASE_CONTAINER} sentinel -> ALLOWED.
test_allows_base_container_sentinel if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "arg", "Value": ["BASE_CONTAINER=ghcr.io/nq-rdl/docker-stacks-foundation-ubi9:2026.6.0@sha256:abc"]},
		{"Cmd": "from", "Value": ["${BASE_CONTAINER}"]},
	]
	count(msgs) == 0
}

# A direct ghcr.io/nq-rdl chained base -> ALLOWED.
test_allows_ghcr_internal_base if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["ghcr.io/nq-rdl/base-notebook-ubi9:2026.6.0@sha256:abc"]},
	]
	count(msgs) == 0
}

# A UBI base -> ALLOWED.
test_allows_ubi_base if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["registry.access.redhat.com/ubi9/ubi:9.8@sha256:abc"]},
	]
	count(msgs) == 0
}

# An arbitrary external base -> DENIED.
test_denies_dockerhub_base if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["ubuntu:24.04"]},
	]
	count(msgs) == 1
}

# A waived vendor base (non_ubi_base_exceptions) -> ALLOWED, in every pin form.
# The digest-only case is the important one: it is the STRICTER pin, so a waiver that
# only understood ":tag" would reject it while accepting the looser tagged form.
test_allows_waived_vendor_base_tag_and_digest if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook:latest@sha256:abc"]},
	]
	count(msgs) == 0
}

test_allows_waived_vendor_base_digest_only if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook@sha256:abc"]},
	]
	count(msgs) == 0
}

test_allows_waived_vendor_base_tag_only if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook:latest"]},
	]
	count(msgs) == 0
}

test_allows_waived_vendor_base_bare if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook"]},
	]
	count(msgs) == 0
}

# A look-alike repository that merely shares a waived repo's prefix -> DENIED, in every
# pin form. Guards the delimiter anchoring in excepted_base: a bare startswith on the
# repository name alone would waive all of these.
test_denies_lookalike_of_waived_base_tagged if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook-fork:latest@sha256:abc"]},
	]
	count(msgs) == 1
}

test_denies_lookalike_of_waived_base_digest_only if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook-fork@sha256:abc"]},
	]
	count(msgs) == 1
}

test_denies_lookalike_of_waived_base_bare if {
	msgs := {m | some m in deny; contains(m, "Final FROM")} with input as [
		{"Cmd": "from", "Value": ["quay.io/jupyter/datascience-notebook-fork"]},
	]
	count(msgs) == 1
}
