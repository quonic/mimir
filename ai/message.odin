package ai

import "core:strings"

Message_Role :: enum {
	System,
	User,
	Assistant,
	Tool,
}

Tool_Definition :: struct {
	name:           string,
	description:    string,
	parametersJSON: string,
}

Tool_Call :: struct {
	id:        string,
	name:      string,
	arguments: string,
}

Tool_Result :: struct {
	toolCallID: string,
	content:    string,
	isError:    bool,
}

Message :: struct {
	role:        Message_Role,
	content:     string,
	toolCalls:   []Tool_Call,
	toolResults: []Tool_Result,
}

Chat_Request :: struct {
	model:       string,
	messages:    []Message,
	tools:       []Tool_Definition,
	temperature: f32,
	maxTokens:   int,
}

Chat_Response :: struct {
	content:      string,
	model:        string,
	finishReason: string,
	toolCalls:    [dynamic]Tool_Call,
}

Chat_Stream_Delta :: struct {
	content:      string,
	model:        string,
	finishReason: string,
	toolCall:     Tool_Call,
	hasToolCall:  bool,
	toolCallDone: bool,
	done:         bool,
}

Chat_Stream_Callback :: #type proc(delta: Chat_Stream_Delta) -> bool
Chat_Stream_Context_Callback :: #type proc(delta: Chat_Stream_Delta, userData: rawptr) -> bool

message_role_to_string :: proc(role: Message_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	case:
		return "user"
	}
}

message_role_from_string :: proc(role: string) -> Message_Role {
	switch role {
	case "system":
		return .System
	case "assistant":
		return .Assistant
	case "tool":
		return .Tool
	case "user":
		fallthrough
	case:
		return .User
	}
}

tool_call_clone :: proc(call: Tool_Call, allocator := context.allocator) -> Tool_Call {
	return Tool_Call {
		id = strings.clone(call.id, allocator),
		name = strings.clone(call.name, allocator),
		arguments = strings.clone(call.arguments, allocator),
	}
}

tool_call_destroy :: proc(call: ^Tool_Call, allocator := context.allocator) {
	if call.id != "" {
		delete(call.id, allocator)
	}
	if call.name != "" {
		delete(call.name, allocator)
	}
	if call.arguments != "" {
		delete(call.arguments, allocator)
	}
	call^ = {}
}

tool_result_destroy :: proc(result: ^Tool_Result, allocator := context.allocator) {
	if result.toolCallID != "" {
		delete(result.toolCallID, allocator)
	}
	if result.content != "" {
		delete(result.content, allocator)
	}
	result^ = {}
}

tool_result_clone :: proc(result: Tool_Result, allocator := context.allocator) -> Tool_Result {
	return Tool_Result {
		toolCallID = strings.clone(result.toolCallID, allocator),
		content = strings.clone(result.content, allocator),
		isError = result.isError,
	}
}

message_clone :: proc(message: Message, allocator := context.allocator) -> Message {
	clone := Message {
		role = message.role,
		content = strings.clone(message.content, allocator),
		toolCalls = make([]Tool_Call, len(message.toolCalls), allocator),
		toolResults = make([]Tool_Result, len(message.toolResults), allocator),
	}
	for call, index in message.toolCalls {
		clone.toolCalls[index] = tool_call_clone(call, allocator)
	}
	for result, index in message.toolResults {
		clone.toolResults[index] = tool_result_clone(result, allocator)
	}
	return clone
}

message_destroy :: proc(message: ^Message, allocator := context.allocator) {
	if message.content != "" {
		delete(message.content, allocator)
	}
	for &call in message.toolCalls {
		tool_call_destroy(&call, allocator)
	}
	delete(message.toolCalls, allocator)
	for &result in message.toolResults {
		tool_result_destroy(&result, allocator)
	}
	delete(message.toolResults, allocator)
	message^ = {}
}

chat_response_destroy :: proc(response: ^Chat_Response, allocator := context.allocator) {
	if response.content != "" {
		delete(response.content, allocator)
	}
	if response.model != "" {
		delete(response.model, allocator)
	}
	if response.finishReason != "" {
		delete(response.finishReason, allocator)
	}
	for &call in response.toolCalls {
		tool_call_destroy(&call, allocator)
	}
	delete(response.toolCalls)
	response^ = {}
}
