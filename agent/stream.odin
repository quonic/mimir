package agent

import ai "../ai"
import "core:strings"

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
