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
