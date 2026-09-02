package main

import "agent"
import "ai"
import "core:strings"
import "core:testing"
import "tool_policy"

@(test)
test_agent_host_starts_active_and_background_agents :: proc(t: ^testing.T) {
	host := agent_host_init(context.temp_allocator)
	defer agent_host_destroy(&host)

	assert(
		agent_host_start_active(&host, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	activeState, activeOK := agent.runtime_state(&host.runtime, host.activeAgentID)
	assert(activeOK && activeState == .Streaming, "expected active agent to be streaming")
	backgroundID, backgroundErr := agent_host_start_background(&host, agent.Agent_Start_Options{})
	assert(backgroundErr == .None, "expected background agent to start")
	backgroundState, backgroundOK := agent.runtime_state(&host.runtime, backgroundID)
	assert(backgroundOK && backgroundState == .Idle, "expected idle background agent")
	_ = t
}

@(test)
test_agent_host_stream_requires_a_selected_provider :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.selectedProvider = ""

	assert(
		!app_start_agent_host_stream(&state),
		"expected missing provider to reject stream start",
	)
	assert(state.status == "No provider selected", "expected missing provider status")
	_ = t
}

@(test)
test_agent_host_projects_streamed_text_into_one_history_entry :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "first "},
		) ==
		.None,
		"expected first text delta",
	)
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "response", done = true},
		) ==
		.None,
		"expected final text delta",
	)
	assert(app_poll_agent_host(&state), "expected projected runtime events")
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Assistant, "expected assistant history entry")
	assert(entry.content == "first response", "expected combined streamed text")
	assert(state.status == "Assistant response complete", "expected completion status")
	_ = t
}

@(test)
test_agent_host_projects_thinking_spinner_before_text :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Hidden reasoning", isThinking = true},
		) ==
		.None,
		"expected thinking delta",
	)
	assert(app_poll_agent_host(&state), "expected thinking projection")
	assert(state.agentHost.historyIndex >= 0, "expected pending assistant history entry")
	assert(
		history_display_line(&state, state.agentHost.historyIndex, context.temp_allocator) ==
		SPINNER_FRAMES[0],
		"expected spinner in pending assistant entry",
	)
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Visible response"},
		) ==
		.None,
		"expected text delta",
	)
	assert(app_poll_agent_host(&state), "expected text projection")
	assert(
		state.history[state.agentHost.historyIndex].content == "Visible response",
		"expected visible text to replace spinner",
	)
	_ = t
}

@(test)
test_agent_host_shows_spinner_while_provider_is_processing :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	// Mirrors the placeholder app_start_agent_host_stream appends before any delta arrives.
	append_history(&state, .Assistant, "")
	state.agentHost.historyIndex = len(state.history) - 1

	assert(app_poll_agent_host(&state), "expected spinner to appear before any delta arrives")
	assert(
		!state.agentHost.thinking,
		"expected spinner to show while processing without a thinking delta",
	)
	assert(state.agentHost.spinnerVisible, "expected spinner to be visible while processing")
	assert(
		app_agent_host_spinner_frame(&state) == SPINNER_FRAMES[0],
		"expected first spinner frame while processing",
	)
	_ = t
}

@(test)
test_agent_host_denies_invalid_tool_requests_and_resumes_agent :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request{id = "call-1", name = "unknown_tool", arguments = `{}`},
		) ==
		.None,
		"expected tool request",
	)
	assert(app_poll_agent_host(&state), "expected tool event to be dispatched")
	assert(state.status == "Tool call denied", "expected denied tool status")
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Tool, "expected denied tool history entry")
	assert(entry.content == "unknown_tool (denied)", "expected denied tool history status")
	agentState, agentOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(agentOK && agentState == .Streaming, "expected denied tool to resume the agent")
	_ = t
}

@(test)
test_agent_host_approval_retains_runtime_request_identity :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		app_show_agent_approval(
			&state,
			tool_policy.Tool_Call{id = "write_file", filePath = "generated/output.txt"},
			agentID,
			"call-1",
		),
		"expected approval modal",
	)
	assert(app_has_overlay(&state, Approval_Overlay), "expected approval mode")
	assert(state.approval.agentID == agentID, "expected approval agent ID")
	assert(state.approval.agentRequestID == "call-1", "expected approval request ID")
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Tool, "expected pending tool history entry")
	assert(
		entry.content == "write_file: generated/output.txt (awaiting approval)",
		"expected pending tool history status",
	)
	_ = t
}

@(test)
test_agent_approval_denial_resolves_the_runtime_request :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request{id = "call-1", name = "write_file", arguments = `{}`},
		) ==
		.None,
		"expected runtime tool request",
	)
	requestEvent, requestEventOK := agent.runtime_next_event(&state.agentHost.runtime, agentID)
	assert(requestEventOK, "expected runtime tool event")
	defer agent.agent_event_destroy(&requestEvent, context.allocator)
	assert(
		app_show_agent_approval(
			&state,
			tool_policy.Tool_Call{id = "write_file", filePath = "generated/output.txt"},
			agentID,
			requestEvent.requestID,
		),
		"expected approval modal",
	)
	app_apply_approval_choice(&state, .Deny)
	assert(len(state.overlayStack) == 0, "expected approval denial to return to chat")
	assert(state.status == "Tool call denied", "expected denial status")
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Tool, "expected denied tool history entry")
	assert(
		entry.content == "write_file: generated/output.txt (denied)",
		"expected pending entry to become denied",
	)
	agentState, agentOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(agentOK && agentState == .Streaming, "expected denied request to resume agent")
	_ = t
}

@(test)
test_agent_host_records_invalid_tool_requests :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request{id = "call-1", name = "run_in_terminal", arguments = ""},
		) ==
		.None,
		"expected tool request",
	)
	assert(app_poll_agent_host(&state), "expected invalid tool request to be dispatched")
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Tool, "expected invalid tool history entry")
	assert(entry.content == "run_in_terminal (failed)", "expected invalid tool history status")
	_ = t
}

@(test)
test_agent_allow_once_executes_and_resumes_runtime :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = "call-1",
				name = "run_in_terminal",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)
	assert(app_poll_agent_host(&state), "expected tool request to open approval")
	assert(app_has_overlay(&state, Approval_Overlay), "expected approval mode")
	app_apply_approval_choice(&state, .Allow_Once)
	assert(state.toolExecution.active, "expected approved tool execution to start")
	runtimeState, runtimeOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Executing_Tool, "expected runtime tool execution state")
	_ = app_poll_agent_host(&state)
	for !app_poll_tool_execution(&state) {
	}
	runtimeState, runtimeOK = agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Streaming, "expected completed tool to resume runtime")
	_ = t
}

@(test)
test_agent_deny_all_resolves_request_without_modal :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.approvalMethod = .Deny_All
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = "call-1",
				name = "run_in_terminal",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)

	assert(app_poll_agent_host(&state), "expected automatic denial to process request")
	assert(len(state.overlayStack) == 0, "expected automatic denial not to open modal")
	runtimeState, runtimeOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Streaming, "expected denied request to resume agent")
	_ = t
}

@(test)
test_agent_allowed_find_code_starts_tool_execution :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = "call-1",
				name = "find_code",
				arguments = `{"query":"agent_host_start_background"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)

	assert(app_poll_agent_host(&state), "expected allowed tool request to be dispatched")
	assert(state.toolExecution.active, "expected allowed tool execution to start")
	runtimeState, runtimeOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Executing_Tool, "expected executing runtime state")
	for !app_poll_tool_execution(&state) {
	}
	runtimeState, runtimeOK = agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Streaming, "expected tool completion to resume runtime")
	_ = t
}

@(test)
test_agent_approve_all_starts_tool_without_modal :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.approvalMethod = .Approve_All
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = "call-1",
				name = "run_in_terminal",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)

	assert(app_poll_agent_host(&state), "expected automatic approval to process request")
	assert(len(state.overlayStack) == 0, "expected automatic approval not to open modal")
	assert(state.toolExecution.active, "expected automatic approval to start tool execution")
	runtimeState, runtimeOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Executing_Tool, "expected runtime tool execution state")
	_ = t
}

@(test)
test_agent_tool_execution_projects_output_to_runtime :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = "call-1",
				name = "run_in_terminal",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)
	assert(app_poll_agent_host(&state), "expected tool request to open approval")
	app_apply_approval_choice(&state, .Allow_Once)
	_ = app_poll_agent_host(&state)
	for !app_poll_tool_execution(&state) {
	}
	resultEvent, resultOK := agent.runtime_next_event(&state.agentHost.runtime, agentID)
	assert(resultOK, "expected runtime tool result event")
	defer agent.agent_event_destroy(&resultEvent, context.allocator)
	assert(resultEvent.type == .Tool_Resolved, "expected resolved tool event")
	assert(!resultEvent.isError, "expected successful tool result")
	assert(resultEvent.content != "", "expected projected tool output")
	_ = t
}

@(test)
test_agent_tool_completion_starts_queued_tool_request :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta {
				hasToolCall = true,
				toolCall = ai.Tool_Call {
					id = "call-1",
					name = "run_in_terminal",
					arguments = `{"command":"pwd"}`,
				},
			},
		) ==
		.None,
		"expected first queued tool call",
	)
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta {
				hasToolCall = true,
				toolCall = ai.Tool_Call {
					id = "call-2",
					name = "run_in_terminal",
					arguments = `{"command":"pwd"}`,
				},
				done = true,
			},
		) ==
		.None,
		"expected second queued tool call",
	)
	assert(app_poll_agent_host(&state), "expected first tool request to open approval")
	assert(state.approval.agentRequestID == "call-1", "expected first tool request")
	app_apply_approval_choice(&state, .Allow_Once)
	_ = app_poll_agent_host(&state)
	for !app_poll_tool_execution(&state) {
	}
	assert(app_poll_agent_host(&state), "expected queued tool request to open approval")
	assert(app_has_overlay(&state, Approval_Overlay), "expected queued tool approval")
	assert(state.approval.agentRequestID == "call-2", "expected second tool request")
	_ = t
}

@(test)
test_agent_continuation_text_starts_after_tool_history :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.approvalMethod = .Approve_All
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "I will check the repository."},
		) ==
		.None,
		"expected pre-tool text delta",
	)
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta {
				hasToolCall = true,
				toolCall = ai.Tool_Call {
					id = "call-1",
					name = "run_in_terminal",
					arguments = `{"command":"pwd"}`,
				},
				done = true,
			},
		) ==
		.None,
		"expected tool request delta",
	)
	assert(app_poll_agent_host(&state), "expected pre-tool text and tool request projection")
	assert(state.agentHost.historyIndex == -1, "expected tool request to close assistant entry")
	for !app_poll_tool_execution(&state) {
	}
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Repository status is clean."},
		) ==
		.None,
		"expected continuation text delta",
	)
	assert(app_poll_agent_host(&state), "expected continuation text projection")
	assert(
		state.history[len(state.history) - 1].content == "Repository status is clean.",
		"expected continuation in a new assistant entry",
	)
	assert(
		state.history[len(state.history) - 3].content == "I will check the repository.",
		"expected pre-tool text to remain unchanged",
	)
	_ = t
}

@(test)
test_agent_host_resolves_parent_tool_call_when_subagent_completes :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	parentID := state.agentHost.activeAgentID

	// Drive the parent into Executing_Tool, mirroring a resolved run_subagent call.
	request := agent.Tool_Request {
		id        = "call-1",
		name      = "run_subagent",
		arguments = `{}`,
	}
	assert(
		agent.runtime_request_tool(&state.agentHost.runtime, parentID, request) == .None,
		"expected tool request to register",
	)
	requestedEvent, requestedOK := agent.runtime_next_event(&state.agentHost.runtime, parentID)
	assert(requestedOK, "expected tool requested event")
	agent.agent_event_destroy(&requestedEvent, state.agentHost.runtime.allocator)
	assert(
		agent.runtime_resolve_tool(&state.agentHost.runtime, parentID, "call-1", .Allowed, "") ==
		.None,
		"expected tool resolution to allow execution",
	)
	resolvedEvent, resolvedOK := agent.runtime_next_event(&state.agentHost.runtime, parentID)
	assert(resolvedOK, "expected tool resolved event")
	agent.agent_event_destroy(&resolvedEvent, state.agentHost.runtime.allocator)

	childID, spawnErr := agent.runtime_spawn_child(
		&state.agentHost.runtime,
		parentID,
		agent.Agent_Start_Options{subagentDepthRemaining = 1},
	)
	assert(spawnErr == .None, "expected child to spawn")
	assert(
		agent.runtime_begin(&state.agentHost.runtime, childID) == .None,
		"expected child to begin",
	)

	append(
		&state.agentHost.agentStack,
		Agent_Stack_Frame {
			agentID = parentID,
			historyIndex = -1,
			requestID = strings.clone("call-1", state.agentHost.runtime.allocator),
			task = strings.clone("delegate", state.agentHost.runtime.allocator),
		},
	)
	state.agentHost.activeAgentID = childID

	assert(
		agent.runtime_complete(&state.agentHost.runtime, childID, "child answer") == .None,
		"expected child to complete",
	)

	assert(app_poll_agent_host(&state), "expected poll to report a dirty update")
	assert(len(state.agentHost.agentStack) == 0, "expected subagent stack frame to pop")
	assert(state.agentHost.activeAgentID == parentID, "expected active agent restored to parent")
	parentState, parentStateOK := agent.runtime_state(&state.agentHost.runtime, parentID)
	assert(parentStateOK && parentState == .Streaming, "expected parent to resume streaming")

	found := false
	for entry in state.history {
		if entry.role == .Subagent &&
		   entry.content == "Subagent completed (delegate): child answer" {
			found = true
		}
	}
	assert(found, "expected subagent completion to appear in history")
	_ = t
}
