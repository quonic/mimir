package main

import agent "./agent"
import "ai"
import "core:testing"

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
			Tool_Call{id = "write_file", filePath = "generated/output.txt"},
			agentID,
			"call-1",
		),
		"expected approval modal",
	)
	assert(state.mode == .Approval, "expected approval mode")
	assert(state.approval.agentID == agentID, "expected approval agent ID")
	assert(state.approval.agentRequestID == "call-1", "expected approval request ID")
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
			Tool_Call{id = "write_file", filePath = "generated/output.txt"},
			agentID,
			requestEvent.requestID,
		),
		"expected approval modal",
	)
	app_apply_approval_choice(&state, .Deny)
	assert(state.mode == .Chat, "expected approval denial to return to chat")
	assert(state.status == "Tool call denied", "expected denial status")
	agentState, agentOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(agentOK && agentState == .Streaming, "expected denied request to resume agent")
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
				name = "run_command",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)
	assert(app_poll_agent_host(&state), "expected tool request to open approval")
	assert(state.mode == .Approval, "expected approval mode")
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
				name = "run_command",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)

	assert(app_poll_agent_host(&state), "expected automatic denial to process request")
	assert(state.mode == .Chat, "expected automatic denial not to open modal")
	runtimeState, runtimeOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(runtimeOK && runtimeState == .Streaming, "expected denied request to resume agent")
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
				name = "run_command",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)

	assert(app_poll_agent_host(&state), "expected automatic approval to process request")
	assert(state.mode == .Chat, "expected automatic approval not to open modal")
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
				name = "run_command",
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
	assert(len(state.stream.conversation) == 0, "expected no legacy tool result projection")
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
					name = "run_command",
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
					name = "run_command",
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
	assert(state.mode == .Approval, "expected queued tool approval")
	assert(state.approval.agentRequestID == "call-2", "expected second tool request")
	_ = t
}
