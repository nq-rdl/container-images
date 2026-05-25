package main

import data.helpers

deny[msg] {
	final := helpers.final_stage_instructions
	not _has_user(final)
	msg := "Containerfile must include a USER instruction in the final stage"
}

deny[msg] {
	final := helpers.final_stage_instructions
	_has_user(final)
	user := _last_user(final)
	_is_root(user)
	msg := sprintf("USER must not be root, got: %s", [user])
}

_has_user(instructions) {
	instructions[i].Cmd == "user"
}

_last_user(instructions) := val {
	users := [u | instructions[i].Cmd == "user"; u := instructions[i].Value[0]]
	val := users[count(users) - 1]
}

_is_root(user) {
	user == "root"
}

_is_root(user) {
	user == "0"
}
