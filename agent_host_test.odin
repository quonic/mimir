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
