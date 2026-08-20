package agent

import "core:strings"

Agent_ID :: distinct u64

Agent_State :: enum int {
	Idle,
	Streaming,
	Awaiting_Tool_Resolution,
	Executing_Tool,
	Completed,
	Failed,
	Canceled,
}

Agent_Error :: enum int {
	None,
	Invalid_State,
	Not_Found,
	Parent_Not_Found,
	Parent_Not_Active,
	Invalid_Stream_Request,
	Tool_Resolution_Not_Found,
	Tool_Resolution_Invalid,
}

Tool_Resolution :: enum int {
	Allowed,
	Denied,
}

Agent_Start_Options :: struct {
	parentID:                   Agent_ID,
	projectRoot:                string,
	maxToolContinuations:       int,
	maxRetainedToolOutputBytes: int,
	subagentDepthRemaining:     int,
}

agent_id_is_none :: proc(id: Agent_ID) -> bool {
	return id == Agent_ID(0)
}

agent_state_is_terminal :: proc(state: Agent_State) -> bool {
	return state == .Completed || state == .Failed || state == .Canceled
}

agent_start_options_clone :: proc(
	options: Agent_Start_Options,
	allocator := context.allocator,
) -> Agent_Start_Options {
	return Agent_Start_Options {
		parentID = options.parentID,
		projectRoot = strings.clone(options.projectRoot, allocator),
		maxToolContinuations = options.maxToolContinuations,
		maxRetainedToolOutputBytes = options.maxRetainedToolOutputBytes,
		subagentDepthRemaining = options.subagentDepthRemaining,
	}
}

agent_start_options_destroy :: proc(
	options: ^Agent_Start_Options,
	allocator := context.allocator,
) {
	delete(options.projectRoot, allocator)
	options^ = {}
}
