package agent

import "core:testing"

@(test)
test_runtime_spawns_isolated_background_agents :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)

	firstID, firstErr := runtime_start_background(
		&runtime,
		Agent_Start_Options{projectRoot = "/projects/first"},
	)
	secondID, secondErr := runtime_start_background(
		&runtime,
		Agent_Start_Options{projectRoot = "/projects/second"},
	)

	assert(firstErr == .None, "expected first agent to start")
	assert(secondErr == .None, "expected second agent to start")
	assert(firstID != secondID, "expected distinct agent IDs")
	firstState, firstOK := runtime_state(&runtime, firstID)
	secondState, secondOK := runtime_state(&runtime, secondID)
	assert(firstOK && firstState == .Idle, "expected first agent to be idle")
	assert(secondOK && secondState == .Idle, "expected second agent to be idle")
	_ = t
}

@(test)
test_runtime_child_completion_notifies_parent :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	parentID, parentErr := runtime_start_background(&runtime, Agent_Start_Options{})
	childID, childErr := runtime_spawn_child(&runtime, parentID, Agent_Start_Options{})

	assert(parentErr == .None, "expected parent to start")
	assert(childErr == .None, "expected child to start")
	assert(
		runtime_complete(&runtime, childID, "child result") == .None,
		"expected child completion",
	)

	childEvent, childEventOK := runtime_next_event(&runtime, childID)
	assert(childEventOK, "expected child completion event")
	assert(childEvent.type == .Completed, "expected child completed event")
	agent_event_destroy(&childEvent, context.temp_allocator)
	parentEvent, parentEventOK := runtime_next_event(&runtime, parentID)
	assert(parentEventOK, "expected parent notification event")
	defer agent_event_destroy(&parentEvent, context.temp_allocator)
	assert(parentEvent.type == .Child_Completed, "expected child completion notification")
	assert(parentEvent.agentID == childID, "expected event to identify child")
	assert(parentEvent.parentID == parentID, "expected event to identify parent")
	assert(parentEvent.content == "child result", "expected child result to be forwarded")
	_ = t
}

@(test)
test_runtime_canceling_parent_cancels_active_children :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	parentID, parentErr := runtime_start_background(&runtime, Agent_Start_Options{})
	childID, childErr := runtime_spawn_child(&runtime, parentID, Agent_Start_Options{})

	assert(parentErr == .None, "expected parent to start")
	assert(childErr == .None, "expected child to start")
	assert(runtime_cancel(&runtime, parentID) == .None, "expected parent cancellation")
	parentState, parentOK := runtime_state(&runtime, parentID)
	childState, childOK := runtime_state(&runtime, childID)
	assert(parentOK && parentState == .Canceled, "expected canceled parent")
	assert(childOK && childState == .Canceled, "expected canceled child")
	_ = t
}

@(test)
test_runtime_resolves_tool_requests_without_host_policy_dependency :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	agentID, startErr := runtime_start_background(&runtime, Agent_Start_Options{})
	assert(startErr == .None, "expected agent to start")
	assert(runtime_begin(&runtime, agentID) == .None, "expected agent to begin streaming")
	request := Tool_Request {
		id        = "call-1",
		name      = "read_file",
		arguments = `{}`,
	}
	assert(runtime_request_tool(&runtime, agentID, request) == .None, "expected tool request")

	requested, requestedOK := runtime_next_event(&runtime, agentID)
	assert(requestedOK, "expected tool request event")
	assert(requested.type == .Tool_Requested, "expected tool requested event")
	assert(requested.toolRequest.name == "read_file", "expected tool request payload")
	agent_event_destroy(&requested, context.temp_allocator)
	assert(
		runtime_resolve_tool(&runtime, agentID, "call-1", .Denied, "Permission denied.") == .None,
		"expected denied tool resolution",
	)
	resolved, resolvedOK := runtime_next_event(&runtime, agentID)
	assert(resolvedOK, "expected tool resolved event")
	defer agent_event_destroy(&resolved, context.temp_allocator)
	assert(resolved.type == .Tool_Resolved, "expected tool resolved event")
	assert(resolved.isError, "expected denied tool to be marked as error")
	assert(resolved.content == "Permission denied.", "expected denial output")
	state, stateOK := runtime_state(&runtime, agentID)
	assert(stateOK && state == .Streaming, "expected agent to resume streaming")
	_ = t
}
