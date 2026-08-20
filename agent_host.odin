package main

import "agent"
import "ai"
import "core:encoding/json"
import "core:fmt"
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
	// Suspended parent frames while a create_subagent tool call is awaiting its child's result.
	agentStack:          [dynamic]Agent_Stack_Frame,
	subagentSpawnCount:  int,
	maxSubagents:        int,
}

Agent_Stack_Frame :: struct {
	agentID:      agent.Agent_ID,
	historyIndex: int,
	requestID:    string,
	task:         string,
}

agent_host_init :: proc(allocator := context.allocator) -> Agent_Host {
	return Agent_Host {
		runtime = agent.runtime_init(allocator),
		historyIndex = -1,
		agentStack = make([dynamic]Agent_Stack_Frame, 0, 0, allocator),
		maxSubagents = settings.DEFAULT_MAX_SUBAGENTS_PER_SESSION,
	}
}

agent_host_destroy :: proc(host: ^Agent_Host) {
	for &frame in host.agentStack {
		delete(frame.requestID, host.runtime.allocator)
		delete(frame.task, host.runtime.allocator)
	}
	delete(host.agentStack)
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
	if len(state.agentHost.agentStack) > 0 {
		if childState, childStateOK := agent.runtime_state(&state.agentHost.runtime, activeID);
		   childStateOK && agent.agent_state_is_terminal(childState) {
			dirty = app_finish_subagent(state, activeID, childState) || dirty
		}
	}
	shouldSpin :=
		app_agent_host_stream_active(state) &&
		state.agentHost.historyIndex >= 0 &&
		state.agentHost.historyIndex < len(state.history) &&
		state.history[state.agentHost.historyIndex].content == ""
	spinnerDirty := app_update_agent_host_spinner(&state.agentHost, shouldSpin)
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

// Resolves the parent's pending create_subagent tool call with the finished child's result.
app_finish_subagent :: proc(
	state: ^App_State,
	childID: agent.Agent_ID,
	childState: agent.Agent_State,
) -> bool {
	stackLen := len(state.agentHost.agentStack)
	if stackLen == 0 {
		return false
	}
	frame := state.agentHost.agentStack[stackLen - 1]
	ordered_remove(&state.agentHost.agentStack, stackLen - 1)

	// Discard the automatic Child_Completed notification; we resolve the tool call directly instead.
	if pendingEvent, hasPending := agent.runtime_next_event(
		&state.agentHost.runtime,
		frame.agentID,
	); hasPending {
		agent.agent_event_destroy(&pendingEvent, state.agentHost.runtime.allocator)
	}

	result, _ := agent.runtime_final_result(&state.agentHost.runtime, childID)
	isError := childState != .Completed
	if isError && result == "" {
		result = "Subagent did not complete."
	}
	if isError {
		append_history(
			state,
			.Subagent,
			fmt.tprintf("Subagent failed (%s): %s", frame.task, result),
		)
	} else {
		append_history(
			state,
			.Subagent,
			fmt.tprintf("Subagent completed (%s): %s", frame.task, result),
		)
	}
	_ = agent.runtime_finish_tool(&state.agentHost.runtime, frame.agentID, result, isError)
	delete(frame.requestID, state.agentHost.runtime.allocator)
	delete(frame.task, state.agentHost.runtime.allocator)
	state.agentHost.activeAgentID = frame.agentID
	state.agentHost.historyIndex = frame.historyIndex
	state.status = "Subagent finished"
	return true
}

app_update_agent_host_spinner :: proc(host: ^Agent_Host, shouldSpin: bool) -> bool {
	if !shouldSpin {
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
	inSubagent := len(state.agentHost.agentStack) > 0
	switch event.type {
	case .Text_Delta:
		role := History_Role.Assistant
		if inSubagent {
			role = .Subagent
		}
		if state.agentHost.historyIndex < 0 || state.agentHost.historyIndex >= len(state.history) {
			append_history(state, role, event.content)
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
				role := History_Role.Assistant
				if inSubagent {
					role = .Subagent
				}
				append_history(state, role, "")
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
	if call.id == "create_subagent" {
		if !app_start_subagent(state, call, historyIndex, event.agentID, event.requestID) {
			app_update_tool_history(state, historyIndex, call, "failed")
			_ = agent.runtime_resolve_tool(
				&state.agentHost.runtime,
				event.agentID,
				event.requestID,
				.Denied,
				"Subagent could not start.",
			)
			state.status = "Subagent could not start"
		}
		return true
	}
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

// Resolves the parent's tool call with an error and marks it handled.
app_fail_subagent_tool :: proc(
	state: ^App_State,
	parentID: agent.Agent_ID,
	message: string,
) -> bool {
	_ = agent.runtime_finish_tool(&state.agentHost.runtime, parentID, message, true)
	return true
}

// Spawns a child agent for a create_subagent tool call and retargets the active agent to it.
// Returns false only if the call could not be resolved at all (caller then finishes it as failed).
app_start_subagent :: proc(
	state: ^App_State,
	call: tool_policy.Tool_Call,
	historyIndex: int,
	parentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	if agent.agent_id_is_none(parentID) || requestID == "" {
		return false
	}
	if agent.runtime_resolve_tool(&state.agentHost.runtime, parentID, requestID, .Allowed, "") !=
	   .None {
		return false
	}

	if state.agentHost.subagentSpawnCount >= state.agentHost.maxSubagents {
		return app_fail_subagent_tool(state, parentID, "Subagent limit reached for this session.")
	}
	depthRemaining, depthOK := agent.runtime_subagent_depth_remaining(
		&state.agentHost.runtime,
		parentID,
	)
	if !depthOK || depthRemaining <= 0 {
		return app_fail_subagent_tool(state, parentID, "Maximum subagent depth reached.")
	}
	if call.task == "" || call.subagentToolsJSON == "" {
		return app_fail_subagent_tool(state, parentID, "A task and tool list are required.")
	}

	requestedNames: []string
	_ = json.unmarshal_string(
		call.subagentToolsJSON,
		&requestedNames,
		allocator = context.temp_allocator,
	)

	provider, providerOK := app_find_provider(state.config, state.config.selectedProvider)
	if !providerOK {
		return app_fail_subagent_tool(state, parentID, "No provider available for subagent.")
	}
	available := app_tool_definitions_for_provider(state, provider.type, context.temp_allocator)
	defer delete(available)

	maxChildDepth := depthRemaining - 1
	if maxChildDepth < 0 {
		maxChildDepth = 0
	}
	childDepth := maxChildDepth
	if call.subagentDepth > 0 && call.subagentDepth < maxChildDepth {
		childDepth = call.subagentDepth
	}

	childTools := make([dynamic]ai.Tool_Definition, 0, len(requestedNames), context.temp_allocator)
	for name in requestedNames {
		if name == "create_subagent" && childDepth <= 0 {
			continue
		}
		for definition in available {
			if definition.name == name {
				append(&childTools, definition)
				break
			}
		}
	}
	if len(childTools) == 0 {
		return app_fail_subagent_tool(
			state,
			parentID,
			"No valid tools were specified for the subagent.",
		)
	}

	childOptions := agent.Agent_Start_Options {
		parentID                   = parentID,
		projectRoot                = state.workingDirectory,
		maxToolContinuations       = state.config.toolContinuations,
		maxRetainedToolOutputBytes = MAX_RETAINED_TOOL_OUTPUT_BYTES,
		subagentDepthRemaining     = childDepth,
	}
	childID, spawnErr := agent.runtime_spawn_child(
		&state.agentHost.runtime,
		parentID,
		childOptions,
	)
	if spawnErr != .None {
		return app_fail_subagent_tool(state, parentID, "Could not spawn subagent.")
	}
	if agent.runtime_begin(&state.agentHost.runtime, childID) != .None {
		return app_fail_subagent_tool(state, parentID, "Could not start subagent.")
	}
	messages := []ai.Message {
		{role = .System, content = SUBAGENT_SYSTEM_PROMPT},
		{role = .User, content = call.task},
	}
	if agent.runtime_set_conversation(&state.agentHost.runtime, childID, messages) != .None {
		return app_fail_subagent_tool(state, parentID, "Could not prepare subagent conversation.")
	}

	client, model, _, temperature, tokenBudget, streamOK :=
		agent.runtime_stream_configuration_view(&state.agentHost.runtime, parentID)
	if !streamOK {
		return app_fail_subagent_tool(state, parentID, "Parent stream configuration unavailable.")
	}
	if agent.runtime_start_stream(
		   &state.agentHost.runtime,
		   childID,
		   client,
		   model,
		   childTools[:],
		   temperature,
		   tokenBudget,
	   ) !=
	   .None {
		return app_fail_subagent_tool(state, parentID, "Could not start subagent stream.")
	}

	append(
		&state.agentHost.agentStack,
		Agent_Stack_Frame {
			agentID = parentID,
			historyIndex = state.agentHost.historyIndex,
			requestID = strings.clone(requestID, state.agentHost.runtime.allocator),
			task = strings.clone(call.task, state.agentHost.runtime.allocator),
		},
	)
	state.agentHost.subagentSpawnCount += 1
	state.agentHost.activeAgentID = childID
	state.agentHost.historyIndex = -1
	app_update_tool_history(state, historyIndex, call, "delegated")
	append_history(state, .Subagent, fmt.tprintf("Subagent started: %s", call.task))
	state.status = "Subagent running"
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
		subagentDepthRemaining     = state.config.maxSubagentDepth,
	}
	state.agentHost.maxSubagents = state.config.maxSubagentsPerSession
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
	tokenBudget := agent.Token_Budget {
		contextWindowTokens = state.agentHost.contextWindowTokens,
		floorTokens         = agent.MIN_OUTPUT_TOKENS_FLOOR,
		fallbackTokens      = agent.DEFAULT_MAX_TOKENS_FALLBACK,
	}
	streamErr := agent.runtime_start_stream(
		&state.agentHost.runtime,
		activeID,
		client,
		model,
		tools[:],
		0.2,
		tokenBudget,
	)
	if streamErr != .None {
		_ = agent.runtime_cancel(&state.agentHost.runtime, activeID)
		state.status = "Agent runtime could not start its stream"
		return false
	}
	// Placeholder entry gives the spinner somewhere to render while the provider is processing.
	append_history(state, .Assistant, "")
	state.agentHost.historyIndex = len(state.history) - 1
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
