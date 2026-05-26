package main

required_labels := {
	"org.opencontainers.image.title",
	"org.opencontainers.image.description",
	"org.opencontainers.image.source",
	"org.opencontainers.image.vendor",
	"org.opencontainers.image.licenses",
}

_label_keys contains key if {
	input[i].Cmd == "label"
	pair := input[i].Value[j]
	key := split(pair, "=")[0]
}

_missing := required_labels - _label_keys

deny contains msg if {
	count(_missing) > 0
	msg := sprintf("Missing required OCI labels: %v", [_missing])
}
