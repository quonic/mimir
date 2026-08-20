package agent

import ai "../ai"
import "core:mem"
import "core:strings"

Agent_Instance :: struct {
	id:             Agent_ID,
	options:        Agent_Start_Options,
	state:          Agent_State,
	children:       [dynamic]Agent_ID,
	events:         [dynamic]Agent_Event,
	conversation:   [dynamic]ai.Message,
	partialBuffer:  [dynamic]byte,
	queuedTools:    [dynamic]Tool_Request,
	stream:         ^Stream_Worker_State,
	streamConfig:   Stream_Configuration,
	finalResult:    string,
	pendingTool:    Tool_Request,
	pendingToolSet: bool,
	thinking:       bool,
	// Most recent provider-reported usage; seeds the next maxTokens estimate.
	lastUsage:      ai.Chat_Usage,
}

// Sizes the response's maxTokens from the model's context window rather than a fixed value.
Token_Budget :: struct {
	contextWindowTokens: int,
	floorTokens:         int,
	fallbackTokens:      int,
}

DEFAULT_MAX_TOKENS_FALLBACK :: 1024 * 64 // Fallback to 64k tokens
MIN_OUTPUT_TOKENS_FLOOR :: 256

Stream_Configuration :: struct {
	client:              ai.Client,
	model:               string,
	tools:               [dynamic]ai.Tool_Definition,
	temperature:         f32,
	tokenBudget:         Token_Budget,
	configured:          bool,
	continuationPending: bool,
}

Runtime :: struct {
	allocator: mem.Allocator,
	nextID:    Agent_ID,
	instances: [dynamic]Agent_Instance,
}

runtime_init :: proc(allocator := context.allocator) -> Runtime {
	return Runtime {
		allocator = allocator,
		nextID = Agent_ID(1),
		instances = make([dynamic]Agent_Instance, 0, 0, allocator),
	}
}

runtime_destroy :: proc(runtime: ^Runtime) {
	for &instance in runtime.instances {
		runtime_destroy_stream(&instance)
		runtime_stream_configuration_destroy(&instance.streamConfig, runtime.allocator)
		agent_start_options_destroy(&instance.options, runtime.allocator)
		for &event in instance.events {
			agent_event_destroy(&event, runtime.allocator)
		}
		delete(instance.events)
		delete(instance.children)
		for &message in instance.conversation {
			runtime_message_destroy(&message, runtime.allocator)
		}
		delete(instance.conversation)
		delete(instance.partialBuffer)
		for &request in instance.queuedTools {
			tool_request_destroy(&request, runtime.allocator)
		}
		delete(instance.queuedTools)
		delete(instance.finalResult, runtime.allocator)
		tool_request_destroy(&instance.pendingTool, runtime.allocator)
	}
	delete(runtime.instances)
	runtime^ = {}
}

runtime_message_destroy :: proc(message: ^ai.Message, allocator := context.allocator) {
	ai.message_destroy(message, allocator)
}

runtime_stream_configuration_destroy :: proc(
	configuration: ^Stream_Configuration,
	allocator := context.allocator,
) {
	delete(configuration.model, allocator)
	for &tool in configuration.tools {
		delete(tool.name, allocator)
		delete(tool.description, allocator)
		delete(tool.parametersJSON, allocator)
	}
	delete(configuration.tools)
	configuration^ = {}
}

runtime_start_background :: proc(
	runtime: ^Runtime,
	options: Agent_Start_Options,
) -> (
	Agent_ID,
	Agent_Error,
) {
	if runtime == nil {
		return Agent_ID(0), .Invalid_State
	}

	id := runtime.nextID
	runtime.nextID = Agent_ID(u64(id) + 1)
	instance := Agent_Instance {
		id            = id,
		options       = agent_start_options_clone(options, runtime.allocator),
		state         = .Idle,
		children      = make([dynamic]Agent_ID, 0, 0, runtime.allocator),
		events        = make([dynamic]Agent_Event, 0, 0, runtime.allocator),
		conversation  = make([dynamic]ai.Message, 0, 0, runtime.allocator),
		partialBuffer = make([dynamic]byte, 0, 0, runtime.allocator),
		queuedTools   = make([dynamic]Tool_Request, 0, 0, runtime.allocator),
	}
	append(&runtime.instances, instance)
	return id, .None
}

runtime_spawn_child :: proc(
	runtime: ^Runtime,
	parentID: Agent_ID,
	options: Agent_Start_Options,
) -> (
	Agent_ID,
	Agent_Error,
) {
	parentIndex, parentOK := runtime_find_index(runtime, parentID)
	if !parentOK {
		return Agent_ID(0), .Parent_Not_Found
	}
	if agent_state_is_terminal(runtime.instances[parentIndex].state) {
		return Agent_ID(0), .Parent_Not_Active
	}

	childOptions := options
	childOptions.parentID = parentID
	childID, err := runtime_start_background(runtime, childOptions)
	if err != .None {
		return Agent_ID(0), err
	}
	append(&runtime.instances[parentIndex].children, childID)
	return childID, .None
}

runtime_state :: proc(runtime: ^Runtime, id: Agent_ID) -> (Agent_State, bool) {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Idle, false
	}
	return runtime.instances[index].state, true
}

// Only valid once the instance has reached a terminal state.
runtime_final_result :: proc(runtime: ^Runtime, id: Agent_ID) -> (string, bool) {
	index, ok := runtime_find_index(runtime, id)
	if !ok || !agent_state_is_terminal(runtime.instances[index].state) {
		return "", false
	}
	return runtime.instances[index].finalResult, true
}

runtime_subagent_depth_remaining :: proc(runtime: ^Runtime, id: Agent_ID) -> (int, bool) {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return 0, false
	}
	return runtime.instances[index].options.subagentDepthRemaining, true
}

// Borrowed view of the instance's active stream configuration; caller must not free the results.
runtime_stream_configuration_view :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
) -> (
	client: ai.Client,
	model: string,
	tools: []ai.Tool_Definition,
	temperature: f32,
	tokenBudget: Token_Budget,
	ok: bool,
) {
	index, found := runtime_find_index(runtime, id)
	if !found || !runtime.instances[index].streamConfig.configured {
		return {}, "", nil, 0, {}, false
	}
	configuration := &runtime.instances[index].streamConfig
	return configuration.client,
		configuration.model,
		configuration.tools[:],
		configuration.temperature,
		configuration.tokenBudget,
		true
}

runtime_begin :: proc(runtime: ^Runtime, id: Agent_ID) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if instance.state != .Idle {
		return .Invalid_State
	}
	instance.state = .Streaming
	return .None
}

runtime_set_conversation :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	messages: []ai.Message,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	canSeedStreaming :=
		instance.state == .Streaming && instance.stream == nil && len(instance.conversation) == 0
	if instance.state != .Idle && !canSeedStreaming {
		return .Invalid_State
	}
	for &message in instance.conversation {
		runtime_message_destroy(&message, runtime.allocator)
	}
	clear(&instance.conversation)
	for message in messages {
		append(&instance.conversation, ai.message_clone(message, runtime.allocator))
	}
	return .None
}

runtime_request_tool :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	request: Tool_Request,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if instance.state != .Streaming || request.id == "" || request.name == "" {
		return .Invalid_State
	}
	instance.pendingTool = tool_request_clone(request, runtime.allocator)
	instance.pendingToolSet = true
	instance.state = .Awaiting_Tool_Resolution
	runtime_emit_event(
		runtime,
		index,
		Agent_Event{type = .Tool_Requested, requestID = request.id, toolRequest = request},
	)
	return .None
}

runtime_resolve_tool :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	requestID: string,
	resolution: Tool_Resolution,
	output: string,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if instance.state != .Awaiting_Tool_Resolution ||
	   !instance.pendingToolSet ||
	   instance.pendingTool.id != requestID {
		return .Tool_Resolution_Not_Found
	}

	if resolution == .Allowed {
		instance.state = .Executing_Tool
		runtime_emit_event(
			runtime,
			index,
			Agent_Event{type = .Tool_Resolved, requestID = requestID},
		)
		return .None
	}
	if resolution != .Denied {
		return .Tool_Resolution_Invalid
	}
	runtime_finish_tool_at_index(runtime, index, output, true)
	return .None
}

runtime_finish_tool :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	output: string,
	isError: bool,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	if runtime.instances[index].state != .Executing_Tool {
		return .Invalid_State
	}
	runtime_finish_tool_at_index(runtime, index, output, isError)
	return .None
}

runtime_complete :: proc(runtime: ^Runtime, id: Agent_ID, result: string) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if agent_state_is_terminal(instance.state) {
		return .Invalid_State
	}

	instance.state = .Completed
	instance.finalResult = strings.clone(result, runtime.allocator)
	runtime_emit_event(runtime, index, Agent_Event{type = .Completed, content = result})
	if !agent_id_is_none(instance.options.parentID) {
		parentIndex, parentOK := runtime_find_index(runtime, instance.options.parentID)
		if parentOK {
			runtime_emit_event(
				runtime,
				parentIndex,
				Agent_Event {
					type = .Child_Completed,
					agentID = instance.id,
					parentID = instance.options.parentID,
					content = result,
				},
			)
		}
	}
	return .None
}

runtime_cancel :: proc(runtime: ^Runtime, id: Agent_ID) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	return runtime_cancel_at_index(runtime, index)
}

runtime_next_event :: proc(runtime: ^Runtime, id: Agent_ID) -> (Agent_Event, bool) {
	index, ok := runtime_find_index(runtime, id)
	if !ok || len(runtime.instances[index].events) == 0 {
		return Agent_Event{}, false
	}

	event := runtime.instances[index].events[0]
	ordered_remove(&runtime.instances[index].events, 0)
	return event, true
}

runtime_find_index :: proc(runtime: ^Runtime, id: Agent_ID) -> (int, bool) {
	if runtime == nil || agent_id_is_none(id) {
		return -1, false
	}
	for index in 0 ..< len(runtime.instances) {
		if runtime.instances[index].id == id {
			return index, true
		}
	}
	return -1, false
}

runtime_cancel_at_index :: proc(runtime: ^Runtime, index: int) -> Agent_Error {
	instance := &runtime.instances[index]
	if agent_state_is_terminal(instance.state) {
		return .Invalid_State
	}

	for childID in instance.children {
		childIndex, childOK := runtime_find_index(runtime, childID)
		if childOK && !agent_state_is_terminal(runtime.instances[childIndex].state) {
			_ = runtime_cancel_at_index(runtime, childIndex)
		}
	}
	if runtime_request_stream_cancel(instance) {
		return .None
	}
	instance.state = .Canceled
	runtime_emit_event(runtime, index, Agent_Event{type = .Canceled})
	return .None
}

runtime_emit_event :: proc(runtime: ^Runtime, index: int, event: Agent_Event) {
	instance := &runtime.instances[index]
	eventCopy := event
	if agent_id_is_none(eventCopy.agentID) {
		eventCopy.agentID = instance.id
	}
	if agent_id_is_none(eventCopy.parentID) {
		eventCopy.parentID = instance.options.parentID
	}
	append(&instance.events, agent_event_clone(eventCopy, runtime.allocator))
}

runtime_finish_tool_at_index :: proc(
	runtime: ^Runtime,
	index: int,
	output: string,
	isError: bool,
) {
	instance := &runtime.instances[index]
	runtime_record_tool_result(runtime, index, instance.pendingTool.id, output, isError)
	tool_request_destroy(&instance.pendingTool, runtime.allocator)
	instance.pendingToolSet = false
	clear(&instance.partialBuffer)
	instance.state = .Streaming
	runtime_emit_event(
		runtime,
		index,
		Agent_Event{type = .Tool_Resolved, content = output, isError = isError},
	)
	if len(instance.queuedTools) > 0 {
		// Another tool from this batch is still queued; defer the stream continuation
		// until the whole batch resolves so we don't race runtime_poll_stream against
		// the Awaiting_Tool_Resolution state that runtime_request_next_tool sets below.
		_ = runtime_request_next_tool(runtime, index)
	} else {
		instance.streamConfig.continuationPending = instance.streamConfig.configured
	}
}
