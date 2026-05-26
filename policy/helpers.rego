package helpers

final_stage_start := idx if {
	from_indices := [i | input[i].Cmd == "from"]
	idx := from_indices[count(from_indices) - 1]
}

final_stage_instructions contains instruction if {
	idx := final_stage_start
	instruction := input[j]
	j >= idx
}
