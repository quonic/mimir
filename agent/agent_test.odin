package agent

import "core:testing"

@(test)
test_agent_state_terminal_values :: proc(t: ^testing.T) {
	assert(!agent_state_is_terminal(.Idle), "expected idle to be non-terminal")
	assert(!agent_state_is_terminal(.Streaming), "expected streaming to be non-terminal")
	assert(
		!agent_state_is_terminal(.Awaiting_Tool_Resolution),
		"expected pending tool to be non-terminal",
	)
	assert(agent_state_is_terminal(.Completed), "expected completed to be terminal")
	assert(agent_state_is_terminal(.Failed), "expected failed to be terminal")
	assert(agent_state_is_terminal(.Canceled), "expected canceled to be terminal")
	_ = t
}

@(test)
test_agent_start_options_clone_owns_project_root :: proc(t: ^testing.T) {
	original := Agent_Start_Options {
		parentID                   = Agent_ID(4),
		projectRoot                = "./project",
		maxToolContinuations       = 1000,
		maxRetainedToolOutputBytes = 64 * 1024,
	}
	clone := agent_start_options_clone(original, context.temp_allocator)
	defer agent_start_options_destroy(&clone, context.temp_allocator)

	assert(clone.parentID == original.parentID, "expected parent ID to be retained")
	assert(clone.projectRoot == original.projectRoot, "expected project root to be retained")
	assert(clone.maxToolContinuations == 1000, "expected continuation limit to be retained")
	assert(clone.maxRetainedToolOutputBytes == 64 * 1024, "expected output limit to be retained")
	_ = t
}
