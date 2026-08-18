package main

import "agent"
import "ai"
import "core:strings"
import "settings"
import "tool_policy"

import "core:time"

SPINNER_FRAME_INTERVAL :: 100 * time.Millisecond

Agent_Host :: struct {
	runtime:             agent.Runtime,
	activeAgentID:       agent.Agent_ID,
	historyIndex:        int,
	thinking:            bool,
	spinnerVisible:      bool,
	spinnerFrameIndex:   int,
	spinnerLastFrame:    time.Tick,
	usage:               ai.Chat_Usage,
	contextWindowTokens: int,
}

agent_host_init :: proc(allocator := context.allocator) -> Agent_Host {
	return Agent_Host{runtime = agent.runtime_init(allocator), historyIndex = -1}
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

app_agent_host_stream_active :: proc(state: ^App_State) -> bool {
	activeID := state.agentHost.activeAgentID
	if agent.agent_id_is_none(activeID) {
		return false
	}
	activeState, activeOK := agent.runtime_state(&state.agentHost.runtime, activeID)
	return activeOK && !agent.agent_state_is_terminal(activeState)
}

app_cancel_agent_host_stream :: proc(state: ^App_State) {
	activeID := state.agentHost.activeAgentID
	if agent.agent_id_is_none(activeID) ||
	   agent.runtime_cancel(&state.agentHost.runtime, activeID) != .None {
		state.status = "No assistant stream to cancel"
		return
	}
	state.status = "Canceling assistant stream"
}

app_poll_agent_host :: proc(state: ^App_State) -> bool {
	dirty, pollErr := agent_host_poll_active(&state.agentHost)
	if pollErr != .None {
		state.status = "Agent runtime polling failed"
		return dirty
	}
	activeID := state.agentHost.activeAgentID
	for {
		event, eventOK := agent.runtime_next_event(&state.agentHost.runtime, activeID)
		if !eventOK {
			break
		}
		dirty = app_apply_agent_event(state, event) || dirty
		agent.agent_event_destroy(&event, state.agentHost.runtime.allocator)
	}
	spinnerDirty := app_update_agent_host_spinner(&state.agentHost)
	if spinnerDirty &&
	   state.agentHost.historyIndex >= 0 &&
	   state.agentHost.historyIndex < len(state.history) {
		entry := &state.history[state.agentHost.historyIndex]
		entry.cachedLineWidth = 0
		entry.cachedLineCount = 0
		state.historyRenderOnly = true
	}
	dirty = spinnerDirty || dirty
	return dirty
}

app_update_agent_host_spinner :: proc(host: ^Agent_Host) -> bool {
	if !host.thinking {
		if !host.spinnerVisible {
			return false
		}
		host.spinnerVisible = false
		host.spinnerFrameIndex = 0
		host.spinnerLastFrame = {}
		return true
	}
	if !host.spinnerVisible {
		host.spinnerVisible = true
		host.spinnerFrameIndex = 0
		host.spinnerLastFrame = time.tick_now()
		return true
	}
	if time.tick_since(host.spinnerLastFrame) < SPINNER_FRAME_INTERVAL {
		return false
	}
	host.spinnerFrameIndex = (host.spinnerFrameIndex + 1) % len(SPINNER_FRAMES)
	host.spinnerLastFrame = time.tick_now()
	return true
}

app_agent_host_spinner_frame :: proc(state: ^App_State) -> string {
	host := &state.agentHost
	if !host.spinnerVisible {
		return ""
	}
	frames := SPINNER_FRAMES
	return frames[host.spinnerFrameIndex]
}
app_apply_agent_event :: proc(state: ^App_State, event: agent.Agent_Event) -> bool {
	switch event.type {
	case .Text_Delta:
		if state.agentHost.historyIndex < 0 || state.agentHost.historyIndex >= len(state.history) {
			append_history(state, .Assistant, event.content)
			state.agentHost.historyIndex = len(state.history) - 1
		} else {
			entry := &state.history[state.agentHost.historyIndex]
			updated := strings.concatenate({entry.content, event.content}, context.allocator)
			delete(entry.content)
			entry.content = updated
			entry.cachedLineWidth = 0
			entry.cachedLineCount = 0
		}
		state.historyRenderOnly = true
		return true
	case .Thinking_Changed:
		state.agentHost.thinking = event.thinking
		if state.agentHost.thinking {
			if state.agentHost.historyIndex < 0 ||
			   state.agentHost.historyIndex >= len(state.history) {
				append_history(state, .Assistant, "")
				state.agentHost.historyIndex = len(state.history) - 1
			}
			state.status = "Assistant thinking"
		}
		return true
	case .Usage_Updated:
		if event.usage.hasInputTokens {
			state.agentHost.usage.inputTokens = event.usage.inputTokens
			state.agentHost.usage.hasInputTokens = true
		}
		if event.usage.hasOutputTokens {
			state.agentHost.usage.outputTokens = event.usage.outputTokens
			state.agentHost.usage.hasOutputTokens = true
		}
		return true
	case .Tool_Requested:
		state.agentHost.historyIndex = -1
		return app_dispatch_agent_tool_request(state, event)
	case .Completed:
		state.status = "Assistant response complete"
		state.agentHost.historyIndex = -1
		return true
	case .Failed:
		append_history(state, .Assistant, event.content)
		state.status = "Assistant stream failed"
		state.agentHost.historyIndex = -1
		return true
	case .Canceled:
		state.status = "Assistant stream canceled"
		state.agentHost.historyIndex = -1
		return true
	case .Child_Completed:
		append_history(state, .Tool, event.content)
		return true
	case .None, .Tool_Resolved:
		return false
	}
	return false
}

app_dispatch_agent_tool_request :: proc(state: ^App_State, event: agent.Agent_Event) -> bool {
	call, callOK := app_tool_call_from_ai(
		ai.Tool_Call {
			id = event.toolRequest.id,
			name = event.toolRequest.name,
			arguments = event.toolRequest.arguments,
		},
		state.dispatcher.allocator,
	)
	if !callOK {
		toolID := event.toolRequest.name
		if toolID == "" {
			toolID = "unknown"
		}
		app_append_tool_history(state, tool_policy.Tool_Call{id = toolID}, "failed")
		_ = agent.runtime_resolve_tool(
			&state.agentHost.runtime,
			event.agentID,
			event.requestID,
			.Denied,
			"Tool call arguments are invalid.",
		)
		state.status = "Tool call rejected"
		return true
	}
	defer tool_policy.tool_call_destroy(&call, state.dispatcher.allocator)

	decision := tool_policy.tool_dispatch_decide(&state.dispatcher, call)
	if decision == .Denied {
		app_append_tool_history(state, call, "denied")
		_ = agent.runtime_resolve_tool(
			&state.agentHost.runtime,
			event.agentID,
			event.requestID,
			.Denied,
			"Permission denied.",
		)
		state.status = "Tool call denied"
		return true
	}
	if decision == .Approval_Required {
		if !app_show_agent_approval(state, call, event.agentID, event.requestID) {
			app_append_tool_history(state, call, "denied")
			_ = agent.runtime_resolve_tool(
				&state.agentHost.runtime,
				event.agentID,
				event.requestID,
				.Denied,
				"Tool call requires approval.",
			)
			state.status = "Tool call rejected"
		}
		return true
	}
	historyIndex := app_append_tool_history(state, call, "running")
	if !app_start_agent_tool_execution(state, call, historyIndex, event.agentID, event.requestID) {
		app_update_tool_history(state, historyIndex, call, "failed")
		_ = agent.runtime_resolve_tool(
			&state.agentHost.runtime,
			event.agentID,
			event.requestID,
			.Denied,
			"Tool call could not start.",
		)
		state.status = "Tool call could not start"
	}
	return true
}

app_show_agent_approval :: proc(
	state: ^App_State,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	if !app_show_approval(state, call) {
		return false
	}
	state.approval.agentID = agentID
	state.approval.agentRequestID = strings.clone(requestID, state.dispatcher.allocator)
	state.approval.historyIndex = app_append_tool_history(state, call, "awaiting approval")
	_ = app_apply_approval_method(state)
	return true
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

	systemPrompt := system_prompt_effective(
		state.config.systemPrompt,
		state.config.systemPromptMode,
		context.temp_allocator,
	)
	defer delete(systemPrompt, context.temp_allocator)
	messages := app_build_ai_messages(state.history[:], systemPrompt, context.temp_allocator)
	defer agent_host_messages_destroy(&messages, context.temp_allocator)
	if len(messages) == 0 {
		state.status = "No chat messages to send"
		return false
	}
	options := agent.Agent_Start_Options {
		projectRoot                = state.workingDirectory,
		maxToolContinuations       = state.config.toolContinuations,
		maxRetainedToolOutputBytes = MAX_RETAINED_TOOL_OUTPUT_BYTES,
	}
	startErr := agent_host_start_active(&state.agentHost, options)
	if startErr != .None {
		state.status = "Agent runtime is already active"
		return false
	}
	activeID := state.agentHost.activeAgentID
	state.agentHost.thinking = false
	state.agentHost.spinnerVisible = false
	state.agentHost.spinnerFrameIndex = 0
	state.agentHost.spinnerLastFrame = {}
	state.agentHost.usage = {}
	state.agentHost.contextWindowTokens = settings.config_context_window_tokens(
		&state.config,
		provider.name,
		model,
	)
	if agent.runtime_set_conversation(&state.agentHost.runtime, activeID, messages[:]) != .None {
		_ = agent.runtime_cancel(&state.agentHost.runtime, activeID)
		state.status = "Agent runtime could not prepare its conversation"
		return false
	}
	tools := app_tool_definitions_for_provider(state, provider.type, context.temp_allocator)
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
