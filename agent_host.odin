package main

import agent "./agent"
import "ai"
import "core:mem"

Agent_Host :: struct {
	runtime:       agent.Runtime,
	activeAgentID: agent.Agent_ID,
}

agent_host_init :: proc(allocator := context.allocator) -> Agent_Host {
	return Agent_Host{runtime = agent.runtime_init(allocator)}
}

agent_host_destroy :: proc(host: ^Agent_Host) {
	agent.runtime_destroy(&host.runtime)
	host^ = {}
}

agent_host_start_active :: proc(
	host: ^Agent_Host,
	options: agent.Agent_Start_Options,
) -> agent.Agent_Error {
	if !agent.agent_id_is_none(host.activeAgentID) {
		state, stateOK := agent.runtime_state(&host.runtime, host.activeAgentID)
		if stateOK && !agent.agent_state_is_terminal(state) {
			return .Invalid_State
		}
	}

	id, err := agent.runtime_start_background(&host.runtime, options)
	if err != .None {
		return err
	}
	if err = agent.runtime_begin(&host.runtime, id); err != .None {
		return err
	}
	host.activeAgentID = id
	return .None
}

agent_host_start_background :: proc(
	host: ^Agent_Host,
	options: agent.Agent_Start_Options,
) -> (
	agent.Agent_ID,
	agent.Agent_Error,
) {
	return agent.runtime_start_background(&host.runtime, options)
}

agent_host_poll_active :: proc(host: ^Agent_Host) -> (bool, agent.Agent_Error) {
	if agent.agent_id_is_none(host.activeAgentID) {
		return false, .None
	}
	return agent.runtime_poll_stream(&host.runtime, host.activeAgentID)
}

app_start_agent_host_stream :: proc(state: ^App_State) -> bool {
	providerName := state.config.selectedProvider
	if providerName == "" {
		state.status = "No provider selected"
		return false
	}
	provider, providerOK := app_find_provider(state.config, providerName)
	if !providerOK || !provider.enabled {
		state.status = "Selected provider is unavailable"
		return false
	}
	model := state.config.selectedModel
	if model == "" {
		model = provider.model
	}
	if model == "" {
		state.status = "No model selected"
		return false
	}
	client, clientErr := ai.new_client(provider.name, provider.apiKey)
	if clientErr != .None {
		state.status = assistant_stream_error_text(clientErr)
		return false
	}

	messages := app_build_ai_messages(state.history[:], context.temp_allocator)
	defer agent_host_messages_destroy(&messages, context.temp_allocator)
	if len(messages) == 0 {
		state.status = "No chat messages to send"
		return false
	}
	options := agent.Agent_Start_Options {
		projectRoot                = state.workingDirectory,
		maxToolContinuations       = MAX_TOOL_CONTINUATIONS,
		maxRetainedToolOutputBytes = MAX_RETAINED_TOOL_OUTPUT_BYTES,
	}
	startErr := agent_host_start_active(&state.agentHost, options)
	if startErr != .None {
		state.status = "Agent runtime is already active"
		return false
	}
	activeID := state.agentHost.activeAgentID
	if agent.runtime_set_conversation(&state.agentHost.runtime, activeID, messages[:]) != .None {
		_ = agent.runtime_cancel(&state.agentHost.runtime, activeID)
		state.status = "Agent runtime could not prepare its conversation"
		return false
	}
	tools := app_tool_definitions_for_provider(provider.type, context.temp_allocator)
	defer delete(tools)
	streamErr := agent.runtime_start_stream(
		&state.agentHost.runtime,
		activeID,
		client,
		model,
		tools[:],
		0.2,
		4096,
	)
	if streamErr != .None {
		_ = agent.runtime_cancel(&state.agentHost.runtime, activeID)
		state.status = "Agent runtime could not start its stream"
		return false
	}
	state.status = "Streaming assistant response"
	return true
}

agent_host_messages_destroy :: proc(
	messages: ^[dynamic]ai.Message,
	allocator := context.allocator,
) {
	for &message in messages^ {
		ai.message_destroy(&message, allocator)
	}
	delete(messages^)
}
