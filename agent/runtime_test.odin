package agent

import ai "../ai"
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

@(test)
test_runtime_stream_delta_records_turn_and_requests_tool :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	agentID, startErr := runtime_start_background(&runtime, Agent_Start_Options{})
	assert(startErr == .None, "expected agent to start")
	assert(runtime_begin(&runtime, agentID) == .None, "expected agent to begin")
	assert(
		runtime_receive_stream_delta(
			&runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "I will inspect it."},
		) ==
		.None,
		"expected text delta",
	)
	assert(
		runtime_receive_stream_delta(
			&runtime,
			agentID,
			ai.Chat_Stream_Delta {
				hasToolCall = true,
				toolCall = ai.Tool_Call {
					id = "call-1",
					name = "read_file",
					arguments = `{"file_path":"README.md"}`,
				},
				done = true,
			},
		) ==
		.None,
		"expected tool-call delta",
	)

	textEvent, textOK := runtime_next_event(&runtime, agentID)
	assert(textOK && textEvent.type == .Text_Delta, "expected text delta event")
	assert(textEvent.content == "I will inspect it.", "expected streamed text")
	agent_event_destroy(&textEvent, context.temp_allocator)
	toolEvent, toolOK := runtime_next_event(&runtime, agentID)
	assert(toolOK && toolEvent.type == .Tool_Requested, "expected tool request event")
	defer agent_event_destroy(&toolEvent, context.temp_allocator)
	assert(toolEvent.toolRequest.id == "call-1", "expected tool request ID")
	state, stateOK := runtime_state(&runtime, agentID)
	assert(stateOK && state == .Awaiting_Tool_Resolution, "expected pending tool resolution")
	_ = t
}

@(test)
test_runtime_post_tool_stream_uses_a_new_assistant_buffer :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	agentID, startErr := runtime_start_background(&runtime, Agent_Start_Options{})
	assert(startErr == .None, "expected agent to start")
	assert(runtime_begin(&runtime, agentID) == .None, "expected agent to begin")
	assert(
		runtime_receive_stream_delta(&runtime, agentID, ai.Chat_Stream_Delta{content = "first"}) ==
		.None,
		"expected first text delta",
	)
	assert(
		runtime_receive_stream_delta(
			&runtime,
			agentID,
			ai.Chat_Stream_Delta {
				hasToolCall = true,
				toolCall = ai.Tool_Call{id = "call-1", name = "read_file", arguments = `{}`},
				done = true,
			},
		) ==
		.None,
		"expected tool turn",
	)
	firstEvent, firstEventOK := runtime_next_event(&runtime, agentID)
	assert(firstEventOK, "expected first text event")
	agent_event_destroy(&firstEvent, context.temp_allocator)
	toolEvent, toolEventOK := runtime_next_event(&runtime, agentID)
	assert(toolEventOK, "expected tool event")
	agent_event_destroy(&toolEvent, context.temp_allocator)
	assert(
		runtime_resolve_tool(&runtime, agentID, "call-1", .Allowed, "") == .None,
		"expected allowed tool resolution",
	)
	resolutionEvent, resolutionEventOK := runtime_next_event(&runtime, agentID)
	assert(resolutionEventOK, "expected tool resolution event")
	agent_event_destroy(&resolutionEvent, context.temp_allocator)
	assert(
		runtime_finish_tool(&runtime, agentID, "contents", false) == .None,
		"expected tool result",
	)
	instanceIndex, instanceOK := runtime_find_index(&runtime, agentID)
	assert(instanceOK, "expected runtime instance")
	assert(
		!runtime.instances[instanceIndex].streamConfig.continuationPending,
		"expected manually driven stream not to schedule a provider continuation",
	)
	resultEvent, resultEventOK := runtime_next_event(&runtime, agentID)
	assert(resultEventOK, "expected tool result event")
	agent_event_destroy(&resultEvent, context.temp_allocator)
	assert(
		runtime_receive_stream_delta(
			&runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "second", done = true},
		) ==
		.None,
		"expected continuation completion",
	)
	textEvent, textEventOK := runtime_next_event(&runtime, agentID)
	assert(textEventOK && textEvent.content == "second", "expected continuation text event")
	agent_event_destroy(&textEvent, context.temp_allocator)
	completeEvent, completeEventOK := runtime_next_event(&runtime, agentID)
	assert(completeEventOK && completeEvent.type == .Completed, "expected completion event")
	defer agent_event_destroy(&completeEvent, context.temp_allocator)
	assert(completeEvent.content == "second", "expected only continuation result")
	_ = t
}

@(test)
test_stream_request_clone_owns_messages_and_tool_definitions :: proc(t: ^testing.T) {
	messages := []ai.Message{{role = .User, content = "inspect the project"}}
	tools := []ai.Tool_Definition {
		{name = "read_file", description = "Read a project file", parametersJSON = `{}`},
	}
	request := runtime_stream_request_clone(
		"test-model",
		messages,
		tools,
		0.2,
		4096,
		context.temp_allocator,
	)
	defer runtime_stream_request_destroy(&request, context.temp_allocator)

	assert(request.model == "test-model", "expected cloned model")
	assert(len(request.messages) == 1, "expected cloned message")
	assert(request.messages[0].content == "inspect the project", "expected cloned message content")
	assert(len(request.tools) == 1, "expected cloned tool")
	assert(request.tools[0].name == "read_file", "expected cloned tool name")
	assert(request.temperature == 0.2, "expected cloned temperature")
	assert(request.maxTokens == 4096, "expected cloned max tokens")
	_ = t
}

@(test)
test_runtime_seeds_active_agent_before_its_worker_starts :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	agentID, startErr := runtime_start_background(&runtime, Agent_Start_Options{})
	assert(startErr == .None, "expected agent to start")
	assert(runtime_begin(&runtime, agentID) == .None, "expected agent to become active")
	assert(
		runtime_set_conversation(
			&runtime,
			agentID,
			[]ai.Message{{role = .User, content = "inspect"}},
		) ==
		.None,
		"expected active agent to accept its initial conversation",
	)
	_ = t
}

@(test)
test_runtime_reports_subagent_depth_and_final_result :: proc(t: ^testing.T) {
	runtime := runtime_init(context.temp_allocator)
	defer runtime_destroy(&runtime)
	agentID, startErr := runtime_start_background(
		&runtime,
		Agent_Start_Options{subagentDepthRemaining = 2},
	)
	assert(startErr == .None, "expected agent to start")

	depth, depthOK := runtime_subagent_depth_remaining(&runtime, agentID)
	assert(depthOK, "expected depth lookup to succeed")
	assert(depth == 2, "expected configured subagent depth to round trip")

	_, resultOK := runtime_final_result(&runtime, agentID)
	assert(!resultOK, "expected no final result before completion")

	assert(runtime_complete(&runtime, agentID, "done") == .None, "expected completion")
	completedEvent, completedOK := runtime_next_event(&runtime, agentID)
	assert(completedOK, "expected completed event")
	agent_event_destroy(&completedEvent, context.temp_allocator)

	result, resultOK2 := runtime_final_result(&runtime, agentID)
	assert(resultOK2, "expected final result after completion")
	assert(result == "done", "expected final result content")
	_ = t
}
