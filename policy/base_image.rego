package main

import data.helpers

deny contains msg if {
	idx := helpers.final_stage_start
	val := input[idx].Value[0]
	not startswith(val, "registry.access.redhat.com/ubi")
	not startswith(val, "registry.redhat.io/ubi")
	msg := sprintf("Final FROM must use a UBI base image, got: %s", [val])
}
