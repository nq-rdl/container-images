package main

deny[msg] {
	input[i].Cmd == "from"
	val := input[i].Value[0]
	not startswith(val, "registry.access.redhat.com/ubi")
	not startswith(val, "registry.redhat.io/ubi")
	msg := sprintf("FROM must use a UBI base image, got: %s", [val])
}
