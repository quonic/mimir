package session

import "../agent"
import "../ai"
import "../settings"
import "../tool_policy"
import "core:encoding/json"
import "core:strings"

Agent_Host :: struct {
	runtime:             agent.Runtime,
	activeAgentID:       agent.Agent_ID,
	thinking:            bool,
	usage:               ai.Chat_Usage,
	contextWindowTokens: int,
	// Suspended parent frames while a run_subagent tool call is awaiting its child's result.
	agentStack:          [dynamic]Agent_Stack_Frame,
	subagentSpawnCount:  int,
	maxSubagents:        int,
}

Agent_Stack_Frame :: struct {
	agentID:    agent.Agent_ID,
	// The session's tool call ID of the run_subagent call.
	toolCallID: string,
	task:       string,
	// The stream error of the child agent, when its stream failed.
	errorText: string,
}

agent_host_init :: proc(allocator := context.allocator) -> Agent_Host {
	return Agent_Host {
		runtime = agent.runtime_init(allocator),
		agentStack = make([dynamic]Agent_Stack_Frame, 0, 0, allocator),
		maxSubagents = settings.DEFAULT_MAX_SUBAGENTS_PER_SESSION,
	}
}

agent_host_destroy :: proc(host: ^Agent_Host) {
	for &frame in host.agentStack {
		agent_stack_frame_destroy(&frame, host.runtime.allocator)
	}
	delete(host.agentStack)
	agent.runtime_destroy(&host.runtime)
	host^ = {}
}

agent_stack_frame_destroy :: proc(frame: ^Agent_Stack_Frame, allocator := context.allocator) {
	delete(frame.toolCallID, allocator)
	delete(frame.task, allocator)
	delete(frame.errorText, allocator)
	frame^ = {}
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

session_poll_agent_host :: proc(session: ^Session) -> bool {
	host := &session.host
	dirty, pollErr := agent_host_poll_active(host)
	if pollErr != .None {
		session_emit_notice(session, "Agent runtime polling failed", .Error)
		return dirty
	}
	activeID := host.activeAgentID
	for {
		event, eventOK := agent.runtime_next_event(&host.runtime, activeID)
		if !eventOK {
			break
		}
		dirty = session_apply_agent_event(session, event) || dirty
		agent.agent_event_destroy(&event, host.runtime.allocator)
	}
	if len(host.agentStack) > 0 {
		if childState, childStateOK := agent.runtime_state(&host.runtime, activeID);
		   childStateOK && agent.agent_state_is_terminal(childState) {
			dirty = session_finish_subagent(session, activeID, childState) || dirty
		}
	}
	return dirty
}

// Resolves the parent's pending run_subagent tool call with the finished child's result.
session_finish_subagent :: proc(
	session: ^Session,
	childID: agent.Agent_ID,
	childState: agent.Agent_State,
) -> bool {
	host := &session.host
	stackLen := len(host.agentStack)
	if stackLen == 0 {
		return false
	}
	frame := host.agentStack[stackLen - 1]
	ordered_remove(&host.agentStack, stackLen - 1)

	// The runtime also queues a Child_Completed event for the parent. The session resolves the
	// tool call here instead, and session_apply_agent_event ignores that event.
	result, _ := agent.runtime_final_result(&host.runtime, childID)
	isError := childState != .Completed
	if isError && result == "" {
		result = "Subagent did not complete."
	}
	allocator := session.allocator
	session_emit(
		session,
		Subagent_Finished {
			parentToolCallID = strings.clone(frame.toolCallID, allocator),
			task = strings.clone(frame.task, allocator),
			result = strings.clone(result, allocator),
			failed = isError,
			errorText = strings.clone(frame.errorText, allocator),
		},
	)
	_ = agent.runtime_finish_tool(&host.runtime, frame.agentID, result, isError)
	host.activeAgentID = frame.agentID
	agent_stack_frame_destroy(&frame, host.runtime.allocator)
	return true
}

// Applies one runtime event: updates the agent host and the transcript, and emits the
// session events.
session_apply_agent_event :: proc(session: ^Session, event: agent.Agent_Event) -> bool {
	host := &session.host
	subagentDepth := len(host.agentStack)
	switch event.type {
	case .Text_Delta:
		if subagentDepth == 0 {
			transcript_append_assistant_text(&session.transcript, event.content)
		}
		parentToolCallID := ""
		if subagentDepth > 0 {
			parentToolCallID = host.agentStack[subagentDepth - 1].toolCallID
		}
		session_emit(
			session,
			Message_Delta {
				text = strings.clone(event.content, session.allocator),
				subagentDepth = subagentDepth,
				parentToolCallID = strings.clone(parentToolCallID, session.allocator),
			},
		)
		return true
	case .Thinking_Changed:
		host.thinking = event.thinking
		session_emit(
			session,
			Thinking_Changed{thinking = event.thinking, subagentDepth = subagentDepth},
		)
		return true
	case .Usage_Updated:
		if event.usage.hasInputTokens {
			host.usage.inputTokens = event.usage.inputTokens
			host.usage.hasInputTokens = true
		}
		if event.usage.hasOutputTokens {
			host.usage.outputTokens = event.usage.outputTokens
			host.usage.hasOutputTokens = true
		}
		session_emit_usage(session)
		return true
	case .Tool_Requested:
		transcript_end_assistant_text(&session.transcript)
		return session_dispatch_agent_tool_request(session, event)
	case .Completed:
		transcript_end_assistant_text(&session.transcript)
		session_end_stream(session, .Completed, "")
		return true
	case .Failed:
		// The error text is part of the transcript, as an assistant message.
		transcript_append_assistant(&session.transcript, event.content)
		session_end_stream(session, .Failed, event.content)
		return true
	case .Canceled:
		transcript_end_assistant_text(&session.transcript)
		session_end_stream(session, .Canceled, "")
		return true
	case .Child_Completed:
		// session_finish_subagent resolves the run_subagent call of the parent.
		return false
	case .None, .Tool_Resolved:
		return false
	}
	return false
}

// The stream of the agent that receives output ended. For the main agent this ends the turn.
// For a subagent, Subagent_Finished follows when the session resolves the parent's tool call.
session_end_stream :: proc(session: ^Session, reason: Turn_End_Reason, errorText: string) {
	host := &session.host
	host.thinking = false
	if stackLen := len(host.agentStack); stackLen > 0 {
		if reason == .Failed {
			frame := &host.agentStack[stackLen - 1]
			delete(frame.errorText, host.runtime.allocator)
			frame.errorText = strings.clone(errorText, host.runtime.allocator)
		}
		return
	}
	session_emit(
		session,
		Turn_Ended{reason = reason, errorText = strings.clone(errorText, session.allocator)},
	)
}

session_emit_usage :: proc(session: ^Session) {
	session_emit(
		session,
		Usage_Updated {
			usage = session.host.usage,
			contextWindowTokens = session.host.contextWindowTokens,
		},
	)
}

session_dispatch_agent_tool_request :: proc(session: ^Session, event: agent.Agent_Event) -> bool {
	host := &session.host
	toolRequest := event.toolRequest
	// The runtime keeps the model's ID (event.requestID). Events use the session's ID.
	toolCallID := session_unique_tool_call_id(session, toolRequest.id)
	call, callOK := tool_call_from_ai(
		ai.Tool_Call {
			id = toolCallID,
			name = toolRequest.name,
			arguments = toolRequest.arguments,
		},
		session.dispatcher.allocator,
	)
	if !callOK {
		toolID := toolRequest.name
		if toolID == "" {
			toolID = "unknown"
		}
		output := "Tool call arguments are invalid."
		session_emit_tool_call_started(session, toolCallID, toolID, "", toolRequest.arguments)
		session_emit_tool_call_updated(session, toolCallID, .Failed, output)
		_ = agent.runtime_resolve_tool(
			&host.runtime,
			event.agentID,
			event.requestID,
			.Denied,
			output,
		)
		session_emit_notice(session, "Tool call rejected", .Warning)
		return true
	}
	defer tool_policy.tool_call_destroy(&call, session.dispatcher.allocator)

	session_emit_tool_call_started(
		session,
		call.callID,
		call.id,
		tool_call_target(call),
		toolRequest.arguments,
	)
	decision := tool_policy.tool_dispatch_decide(&session.dispatcher, call)
	if decision == .Denied {
		output := "Permission denied."
		session_emit_tool_call_updated(session, call.callID, .Denied, output)
		_ = agent.runtime_resolve_tool(
			&host.runtime,
			event.agentID,
			event.requestID,
			.Denied,
			output,
		)
		session_emit_notice(session, "Tool call denied", .Warning)
		return true
	}
	if decision == .Approval_Required {
		if session_request_approval(session, call, event.agentID, event.requestID) == .Rejected {
			output := "Tool call requires approval."
			session_emit_tool_call_updated(session, call.callID, .Denied, output)
			_ = agent.runtime_resolve_tool(
				&host.runtime,
				event.agentID,
				event.requestID,
				.Denied,
				output,
			)
			session_emit_notice(session, "Tool call rejected", .Warning)
		}
		return true
	}
	session_emit_tool_call_updated(session, call.callID, .Running)
	session_run_allowed_tool(session, call, event.agentID, event.requestID)
	return true
}

// Runs an allowed tool call: run_subagent starts a subagent, and every other tool runs on the
// tool worker. When the call cannot start, it fails the call.
session_run_allowed_tool :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) {
	host := &session.host
	if call.id == "run_subagent" {
		if !session_start_subagent(session, call, agentID, requestID) {
			output := "Subagent could not start."
			session_emit_tool_call_updated(session, call.callID, .Failed, output)
			_ = agent.runtime_resolve_tool(&host.runtime, agentID, requestID, .Denied, output)
			session_emit_notice(session, "Subagent could not start", .Error)
		}
		return
	}
	if !session_start_agent_tool_execution(session, call, agentID, requestID) {
		output := "Tool call could not start."
		session_emit_tool_call_updated(session, call.callID, .Failed, output)
		_ = agent.runtime_resolve_tool(&host.runtime, agentID, requestID, .Denied, output)
		session_emit_notice(session, "Tool call could not start", .Error)
	}
}

// Resolves the parent's tool call with an error and marks it handled.
session_fail_subagent_tool :: proc(
	session: ^Session,
	parentID: agent.Agent_ID,
	message: string,
) -> bool {
	_ = agent.runtime_finish_tool(&session.host.runtime, parentID, message, true)
	return true
}

// Spawns a child agent for a run_subagent tool call and retargets the active agent to it.
// Returns false only if the call could not be resolved at all (caller then finishes it as failed).
session_start_subagent :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	parentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	host := &session.host
	config := session.config
	if agent.agent_id_is_none(parentID) || requestID == "" {
		return false
	}
	if agent.runtime_resolve_tool(&host.runtime, parentID, requestID, .Allowed, "") != .None {
		return false
	}

	if host.subagentSpawnCount >= host.maxSubagents {
		return session_fail_subagent_tool(
			session,
			parentID,
			"Subagent limit reached for this session.",
		)
	}
	depthRemaining, depthOK := agent.runtime_subagent_depth_remaining(&host.runtime, parentID)
	if !depthOK || depthRemaining <= 0 {
		return session_fail_subagent_tool(session, parentID, "Maximum subagent depth reached.")
	}
	if call.task == "" || call.subagentToolsJSON == "" {
		return session_fail_subagent_tool(session, parentID, "A task and tool list are required.")
	}

	requestedNames: []string
	_ = json.unmarshal_string(
		call.subagentToolsJSON,
		&requestedNames,
		allocator = context.temp_allocator,
	)

	provider, providerOK := settings.config_find_provider(config^, session.providerName)
	if !providerOK {
		return session_fail_subagent_tool(
			session,
			parentID,
			"No provider available for subagent.",
		)
	}
	available := tool_definitions_for_provider(provider.type, context.temp_allocator)
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
		if name == "run_subagent" && childDepth <= 0 {
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
		return session_fail_subagent_tool(
			session,
			parentID,
			"No valid tools were specified for the subagent.",
		)
	}

	childOptions := agent.Agent_Start_Options {
		parentID                   = parentID,
		projectRoot                = session.projectRoot,
		maxToolContinuations       = config.toolContinuations,
		maxRetainedToolOutputBytes = MAX_RETAINED_TOOL_OUTPUT_BYTES,
		subagentDepthRemaining     = childDepth,
	}
	childID, spawnErr := agent.runtime_spawn_child(&host.runtime, parentID, childOptions)
	if spawnErr != .None {
		return session_fail_subagent_tool(session, parentID, "Could not spawn subagent.")
	}
	if agent.runtime_begin(&host.runtime, childID) != .None {
		return session_fail_subagent_tool(session, parentID, "Could not start subagent.")
	}
	childSystemPrompt := strings.concatenate(
		{
			SUBAGENT_SYSTEM_PROMPT,
			"\n\n",
			get_skills_list(session.skills.skills[:], context.temp_allocator),
		},
		context.temp_allocator,
	)
	defer delete(childSystemPrompt, context.temp_allocator)
	messages := []ai.Message {
		{role = .System, content = childSystemPrompt},
		{role = .User, content = call.task},
	}
	if agent.runtime_set_conversation(&host.runtime, childID, messages) != .None {
		return session_fail_subagent_tool(
			session,
			parentID,
			"Could not prepare subagent conversation.",
		)
	}

	client, model, _, temperature, tokenBudget, streamOK :=
		agent.runtime_stream_configuration_view(&host.runtime, parentID)
	if !streamOK {
		return session_fail_subagent_tool(
			session,
			parentID,
			"Parent stream configuration unavailable.",
		)
	}
	if agent.runtime_start_stream(
		   &host.runtime,
		   childID,
		   client,
		   model,
		   childTools[:],
		   temperature,
		   tokenBudget,
	   ) !=
	   .None {
		return session_fail_subagent_tool(session, parentID, "Could not start subagent stream.")
	}

	append(
		&host.agentStack,
		Agent_Stack_Frame {
			agentID = parentID,
			toolCallID = strings.clone(call.callID, host.runtime.allocator),
			task = strings.clone(call.task, host.runtime.allocator),
		},
	)
	host.subagentSpawnCount += 1
	host.activeAgentID = childID
	session_emit(
		session,
		Subagent_Started {
			parentToolCallID = strings.clone(call.callID, session.allocator),
			task = strings.clone(call.task, session.allocator),
		},
	)
	return true
}

// Returns the provider and the model of the session. An empty session model uses the model of
// the provider.
session_resolve_model :: proc(
	session: ^Session,
) -> (
	provider: settings.Provider_Config,
	model: string,
	providerOK: bool,
) {
	provider, providerOK = settings.config_find_provider(session.config^, session.providerName)
	if !providerOK {
		return
	}
	model = session.model
	if model == "" {
		model = provider.model
	}
	return
}

// Starts the stream of the main agent for a new turn. It emits a Notice and returns false when
// the stream could not start.
session_start_turn :: proc(session: ^Session) -> bool {
	host := &session.host
	config := session.config
	if session.providerName == "" {
		session_emit_notice(session, "No provider selected", .Error)
		return false
	}
	provider, model, providerOK := session_resolve_model(session)
	if !providerOK || !provider.enabled {
		session_emit_notice(session, "Selected provider is unavailable", .Error)
		return false
	}
	if model == "" {
		session_emit_notice(session, "No model selected", .Error)
		return false
	}
	client, clientErr := ai.new_client(provider.name, provider.apiKey)
	if clientErr != .None {
		session_emit_notice(session, assistant_stream_error_text(clientErr), .Error)
		return false
	}

	systemPrompt := system_prompt_effective(
		model,
		session.skills.skills[:],
		config.systemPrompt,
		config.systemPromptMode,
		context.temp_allocator,
	)
	defer delete(systemPrompt, context.temp_allocator)
	messages := transcript_build_messages(
		&session.transcript,
		systemPrompt,
		context.temp_allocator,
	)
	defer agent_host_messages_destroy(&messages, context.temp_allocator)
	if len(messages) == 0 {
		session_emit_notice(session, "No chat messages to send", .Error)
		return false
	}
	options := agent.Agent_Start_Options {
		projectRoot                = session.projectRoot,
		maxToolContinuations       = config.toolContinuations,
		maxRetainedToolOutputBytes = MAX_RETAINED_TOOL_OUTPUT_BYTES,
		subagentDepthRemaining     = config.maxSubagentDepth,
	}
	host.maxSubagents = config.maxSubagentsPerSession
	startErr := agent_host_start_active(host, options)
	if startErr != .None {
		session_emit_notice(session, "Agent runtime is already active", .Error)
		return false
	}
	activeID := host.activeAgentID
	host.thinking = false
	host.usage = {}
	host.contextWindowTokens = settings.config_context_window_tokens(
		config,
		provider.name,
		model,
	)
	if agent.runtime_set_conversation(&host.runtime, activeID, messages[:]) != .None {
		_ = agent.runtime_cancel(&host.runtime, activeID)
		session_emit_notice(
			session,
			"Agent runtime could not prepare its conversation",
			.Error,
		)
		return false
	}
	tools := tool_definitions_for_provider(provider.type, context.temp_allocator)
	defer delete(tools)
	tokenBudget := agent.Token_Budget {
		contextWindowTokens = host.contextWindowTokens,
		floorTokens         = agent.MIN_OUTPUT_TOKENS_FLOOR,
		fallbackTokens      = agent.DEFAULT_MAX_TOKENS_FALLBACK,
	}
	streamErr := agent.runtime_start_stream(
		&host.runtime,
		activeID,
		client,
		model,
		tools[:],
		0.2,
		tokenBudget,
	)
	if streamErr != .None {
		_ = agent.runtime_cancel(&host.runtime, activeID)
		session_emit_notice(session, "Agent runtime could not start its stream", .Error)
		return false
	}
	session_emit_usage(session)
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

// The tool call field that a front end shows, for example the path of read_file.
tool_call_target :: proc(call: tool_policy.Tool_Call) -> string {
	switch call.id {
	case "read_file", "write_file", "get_file_info", "grep_search":
		return call.filePath
	case "list_directory":
		return call.directoryPath
	case "run_in_terminal":
		return call.command
	case "search_code", "find_code":
		return call.query
	case "run_subagent":
		return call.task
	}
	return ""
}
