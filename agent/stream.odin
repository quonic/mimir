package agent

import ai "../ai"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

Stream_Worker_State :: struct {
	mutex:           sync.Mutex,
	allocator:       mem.Allocator,
	worker:          ^thread.Thread,
	workerData:      ^Stream_Worker,
	pendingDeltas:   [dynamic]ai.Chat_Stream_Delta,
	cancelRequested: bool,
	canceled:        bool,
	finished:        bool,
	err:             ai.AI_Error,
}

Stream_Worker :: struct {
	state:   ^Stream_Worker_State,
	client:  ai.Client,
	request: ai.Chat_Request,
}

runtime_start_stream :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	client: ai.Client,
	model: string,
	tools: []ai.Tool_Definition,
	temperature: f32,
	maxTokens: int,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if instance.state != .Streaming ||
	   instance.stream != nil ||
	   model == "" ||
	   len(instance.conversation) == 0 {
		return .Invalid_Stream_Request
	}

	stream := new(Stream_Worker_State, runtime.allocator)
	stream.allocator = runtime.allocator
	stream.pendingDeltas = make([dynamic]ai.Chat_Stream_Delta, 0, 0, runtime.allocator)
	worker := new(Stream_Worker, runtime.allocator)
	worker.state = stream
	worker.client = client
	worker.request = runtime_stream_request_clone(
		model,
		instance.conversation[:],
		tools,
		temperature,
		maxTokens,
		runtime.allocator,
	)
	stream.workerData = worker
	stream.worker = thread.create(runtime_stream_worker_proc)
	stream.worker.data = rawptr(worker)
	instance.stream = stream
	thread.start(stream.worker)
	return .None
}

runtime_poll_stream :: proc(runtime: ^Runtime, id: Agent_ID) -> (bool, Agent_Error) {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return false, .Not_Found
	}
	instance := &runtime.instances[index]
	stream := instance.stream
	if stream == nil {
		return false, .None
	}

	pendingDeltas: [dynamic]ai.Chat_Stream_Delta
	cancelRequested := false
	if sync.mutex_guard(&stream.mutex) {
		pendingDeltas = stream.pendingDeltas
		stream.pendingDeltas = make([dynamic]ai.Chat_Stream_Delta, 0, 0, stream.allocator)
		cancelRequested = stream.cancelRequested
	}
	defer {
		for &delta in pendingDeltas {
			runtime_stream_delta_destroy(&delta, stream.allocator)
		}
		delete(pendingDeltas)
	}

	dirty := len(pendingDeltas) > 0
	if !cancelRequested {
		for delta in pendingDeltas {
			err := runtime_receive_stream_delta(runtime, id, delta)
			if err != .None && err != .Invalid_State {
				return dirty, err
			}
		}
	}
	if stream.worker == nil || !thread.is_done(stream.worker) {
		return dirty, .None
	}

	canceled := cancelRequested
	err := ai.AI_Error.None
	if sync.mutex_guard(&stream.mutex) {
		canceled = stream.canceled
		err = stream.err
	}
	runtime_destroy_stream(instance)
	if canceled && !agent_state_is_terminal(instance.state) {
		_ = runtime_cancel_at_index(runtime, index)
		return true, .None
	}
	if err != .None && !agent_state_is_terminal(instance.state) {
		instance.state = .Failed
		runtime_emit_event(
			runtime,
			index,
			Agent_Event{type = .Failed, content = "Assistant stream failed.", isError = true},
		)
		return true, .None
	}
	return true, .None
}

runtime_request_stream_cancel :: proc(instance: ^Agent_Instance) -> bool {
	if instance == nil || instance.stream == nil {
		return false
	}
	stream := instance.stream
	if sync.mutex_guard(&stream.mutex) {
		stream.cancelRequested = true
	}
	return stream.worker != nil
}

runtime_destroy_stream :: proc(instance: ^Agent_Instance) {
	if instance == nil || instance.stream == nil {
		return
	}
	stream := instance.stream
	_ = runtime_request_stream_cancel(instance)
	if stream.worker != nil {
		thread.join(stream.worker)
		thread.destroy(stream.worker)
		stream.worker = nil
	}
	if stream.workerData != nil {
		runtime_stream_request_destroy(&stream.workerData.request, stream.allocator)
		free(stream.workerData)
		stream.workerData = nil
	}
	for &delta in stream.pendingDeltas {
		runtime_stream_delta_destroy(&delta, stream.allocator)
	}
	delete(stream.pendingDeltas)
	free(stream)
	instance.stream = nil
}

runtime_stream_worker_proc :: proc(workerThread: ^thread.Thread) {
	worker := cast(^Stream_Worker)workerThread.data
	err := ai.send_chat_completion_stream_with_context(
		worker.client,
		worker.request,
		runtime_stream_delta_callback,
		rawptr(worker.state),
	)
	if sync.mutex_guard(&worker.state.mutex) {
		worker.state.err = err
		worker.state.finished = true
		if worker.state.cancelRequested && err == .None {
			worker.state.canceled = true
		}
	}
}

runtime_stream_delta_callback :: proc(delta: ai.Chat_Stream_Delta, userData: rawptr) -> bool {
	stream := cast(^Stream_Worker_State)userData
	if !sync.mutex_guard(&stream.mutex) {
		return false
	}
	if stream.cancelRequested {
		stream.canceled = true
		return false
	}
	append(&stream.pendingDeltas, runtime_stream_delta_clone(delta, stream.allocator))
	return true
}

runtime_stream_request_clone :: proc(
	model: string,
	messages: []ai.Message,
	tools: []ai.Tool_Definition,
	temperature: f32,
	maxTokens: int,
	allocator := context.allocator,
) -> ai.Chat_Request {
	request := ai.Chat_Request {
		model       = strings.clone(model, allocator),
		messages    = make([]ai.Message, len(messages), allocator),
		tools       = make([]ai.Tool_Definition, len(tools), allocator),
		temperature = temperature,
		maxTokens   = maxTokens,
	}
	for message, index in messages {
		request.messages[index] = ai.message_clone(message, allocator)
	}
	for tool, index in tools {
		request.tools[index] = ai.Tool_Definition {
			name           = strings.clone(tool.name, allocator),
			description    = strings.clone(tool.description, allocator),
			parametersJSON = strings.clone(tool.parametersJSON, allocator),
		}
	}
	return request
}

runtime_stream_request_destroy :: proc(request: ^ai.Chat_Request, allocator := context.allocator) {
	delete(request.model, allocator)
	for &message in request.messages {
		ai.message_destroy(&message, allocator)
	}
	delete(request.messages, allocator)
	for &tool in request.tools {
		delete(tool.name, allocator)
		delete(tool.description, allocator)
		delete(tool.parametersJSON, allocator)
	}
	delete(request.tools, allocator)
	request^ = {}
}

runtime_stream_delta_clone :: proc(
	delta: ai.Chat_Stream_Delta,
	allocator := context.allocator,
) -> ai.Chat_Stream_Delta {
	return ai.Chat_Stream_Delta {
		content = strings.clone(delta.content, allocator),
		model = strings.clone(delta.model, allocator),
		finishReason = strings.clone(delta.finishReason, allocator),
		isThinking = delta.isThinking,
		toolCall = ai.tool_call_clone(delta.toolCall, allocator),
		hasToolCall = delta.hasToolCall,
		toolCallDone = delta.toolCallDone,
		done = delta.done,
		usage = delta.usage,
	}
}

runtime_stream_delta_destroy :: proc(
	delta: ^ai.Chat_Stream_Delta,
	allocator := context.allocator,
) {
	delete(delta.content, allocator)
	delete(delta.model, allocator)
	delete(delta.finishReason, allocator)
	ai.tool_call_destroy(&delta.toolCall, allocator)
	delta^ = {}
}

runtime_receive_stream_delta :: proc(
	runtime: ^Runtime,
	id: Agent_ID,
	delta: ai.Chat_Stream_Delta,
) -> Agent_Error {
	index, ok := runtime_find_index(runtime, id)
	if !ok {
		return .Not_Found
	}
	instance := &runtime.instances[index]
	if instance.state != .Streaming {
		return .Invalid_State
	}

	if delta.isThinking != instance.thinking {
		instance.thinking = delta.isThinking
		runtime_emit_event(
			runtime,
			index,
			Agent_Event{type = .Thinking_Changed, content = delta.content},
		)
	}
	if delta.content != "" && !delta.isThinking {
		append(&instance.partialBuffer, delta.content)
		runtime_emit_event(
			runtime,
			index,
			Agent_Event{type = .Text_Delta, content = delta.content},
		)
	}
	if delta.hasToolCall {
		append(
			&instance.queuedTools,
			tool_request_clone(
				Tool_Request {
					id = delta.toolCall.id,
					name = delta.toolCall.name,
					arguments = delta.toolCall.arguments,
				},
				runtime.allocator,
			),
		)
	}
	if !delta.done {
		return .None
	}

	instance.thinking = false
	runtime_record_assistant_turn(runtime, index)
	if len(instance.queuedTools) > 0 {
		return runtime_request_next_tool(runtime, index)
	}
	return runtime_complete(runtime, id, string(instance.partialBuffer[:]))
}

runtime_request_next_tool :: proc(runtime: ^Runtime, index: int) -> Agent_Error {
	instance := &runtime.instances[index]
	if len(instance.queuedTools) == 0 {
		return .Tool_Resolution_Not_Found
	}
	request := instance.queuedTools[0]
	ordered_remove(&instance.queuedTools, 0)
	return runtime_request_tool(runtime, instance.id, request)
}

runtime_record_assistant_turn :: proc(runtime: ^Runtime, index: int) {
	instance := &runtime.instances[index]
	message := ai.Message {
		role      = .Assistant,
		content   = strings.clone(string(instance.partialBuffer[:]), runtime.allocator),
		toolCalls = make([]ai.Tool_Call, len(instance.queuedTools), runtime.allocator),
	}
	for request, requestIndex in instance.queuedTools {
		message.toolCalls[requestIndex] = ai.Tool_Call {
			id        = strings.clone(request.id, runtime.allocator),
			name      = strings.clone(request.name, runtime.allocator),
			arguments = strings.clone(request.arguments, runtime.allocator),
		}
	}
	append(&instance.conversation, message)
}

runtime_record_tool_result :: proc(
	runtime: ^Runtime,
	index: int,
	toolCallID: string,
	content: string,
	isError: bool,
) {
	instance := &runtime.instances[index]
	message := ai.Message {
		role        = .Tool,
		toolResults = make([]ai.Tool_Result, 1, runtime.allocator),
	}
	message.toolResults[0] = ai.Tool_Result {
		toolCallID = strings.clone(toolCallID, runtime.allocator),
		content    = strings.clone(content, runtime.allocator),
		isError    = isError,
	}
	append(&instance.conversation, message)
}
