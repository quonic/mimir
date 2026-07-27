package main

import agent "./agent"
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
