package image_meta

import rego.v1

_semver_tag := `^\d+\.\d+\.\d+$`

_minor_tag := `^\d+\.\d+$`

_allowed_tag(tag) if tag == "latest"

_allowed_tag(tag) if regex.match(_semver_tag, tag)

_allowed_tag(tag) if regex.match(_minor_tag, tag)

deny contains msg if {
	tag := input.tags[_]
	not _allowed_tag(tag)
	msg := sprintf("Tag %q does not match allowed patterns (X.Y.Z, X.Y, or latest)", [tag])
}

deny contains msg if {
	not input.tags
	msg := "image.yaml must include a 'tags' list"
}

deny contains msg if {
	count(input.tags) == 0
	msg := "image.yaml 'tags' list must not be empty"
}
