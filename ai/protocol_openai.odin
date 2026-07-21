package ai

import json "core:encoding/json"
import "core:strings"

OpenAI_Message :: struct {
	role:         string,
	content:      string,
	tool_call_id: string,
	tool_calls:   []OpenAI_Tool_Call,
}

OpenAI_Function :: struct {
	name:        string,
	description: string,
	parameters:  json.Value,
}

OpenAI_Tool :: struct {
	type:     string,
	function: OpenAI_Function,
}

OpenAI_Tool_Call_Function :: struct {
	name:      string,
	arguments: string,
}

OpenAI_Tool_Call :: struct {
	id:       string,
	type:     string,
	function: OpenAI_Tool_Call_Function,
}

OpenAI_Stream_Tool_Call :: struct {
	index:    int,
	id:       string,
	type:     string,
	function: OpenAI_Tool_Call_Function,
}

OpenAI_Stream_Tool_State :: struct {
	calls: [dynamic]Tool_Call,
}

OpenAI_Chat_Request :: struct {
	model:       string,
	messages:    [dynamic]OpenAI_Message,
	temperature: f32,
	max_tokens:  int,
	stream:      bool,
	tools:       []OpenAI_Tool,
}

OpenAI_Choice_Message :: struct {
	role:       string,
	content:    string,
	tool_calls: []OpenAI_Tool_Call,
}

OpenAI_Choice :: struct {
	message:       OpenAI_Choice_Message,
	finish_reason: string,
}

OpenAI_Chat_Response :: struct {
	model:   string,
	choices: []OpenAI_Choice,
}

OpenAI_Stream_Delta_Message :: struct {
	role:       string,
	content:    string,
	reasoning:  string,
	tool_calls: []OpenAI_Stream_Tool_Call,
}

OpenAI_Stream_Choice :: struct {
	delta:         OpenAI_Stream_Delta_Message,
	finish_reason: string,
}

OpenAI_Stream_Response :: struct {
	model:   string,
	choices: []OpenAI_Stream_Choice,
}

OpenAI_Model :: struct {
	id: string,
}

OpenAI_Models_Response :: struct {
	data: []OpenAI_Model,
}

OpenAI_Error_Detail :: struct {
	message: string,
	type:    string,
}

OpenAI_Error_Response :: struct {
	error: OpenAI_Error_Detail,
}

build_openai_chat_request :: proc(
	request: Chat_Request,
	allocator := context.temp_allocator,
) -> OpenAI_Chat_Request {
	wire := OpenAI_Chat_Request {
		model       = request.model,
		messages    = make([dynamic]OpenAI_Message, 0, len(request.messages), allocator),
		temperature = request.temperature,
		max_tokens  = request.maxTokens,
		stream      = false,
		tools       = make([]OpenAI_Tool, len(request.tools), allocator),
	}

	for msg in request.messages {
		if msg.role == .Tool {
			for result in msg.toolResults {
				append(
					&wire.messages,
					OpenAI_Message {
						role = "tool",
						content = result.content,
						tool_call_id = result.toolCallID,
					},
				)
			}
			continue
		}

		wireMessage := OpenAI_Message {
			role       = message_role_to_string(msg.role),
			content    = msg.content,
			tool_calls = make([]OpenAI_Tool_Call, len(msg.toolCalls), allocator),
		}
		for call, idx in msg.toolCalls {
			wireMessage.tool_calls[idx] = OpenAI_Tool_Call {
				id = call.id,
				type = "function",
				function = OpenAI_Tool_Call_Function{name = call.name, arguments = call.arguments},
			}
		}
		append(&wire.messages, wireMessage)
	}
	for tool, idx in request.tools {
		parameters, parseErr := json.parse_string(tool.parametersJSON, allocator = allocator)
		if parseErr != .None {
			parameters = json.Null(nil)
		}
		wire.tools[idx] = OpenAI_Tool {
			type = "function",
			function = OpenAI_Function {
				name = tool.name,
				description = tool.description,
				parameters = parameters,
			},
		}
	}

	return wire
}

build_openai_chat_stream_request :: proc(request: Chat_Request) -> OpenAI_Chat_Request {
	wire := build_openai_chat_request(request)
	wire.stream = true
	return wire
}

parse_openai_chat_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	Chat_Response,
	AI_Error,
) {
	wire: OpenAI_Chat_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return Chat_Response{}, .Invalid_Response
	}

	if len(wire.choices) == 0 {
		return Chat_Response{}, .Invalid_Response
	}

	choice := wire.choices[0]
	response := Chat_Response {
		content      = strings.clone(choice.message.content, allocator),
		model        = strings.clone(wire.model, allocator),
		finishReason = strings.clone(choice.finish_reason, allocator),
		toolCalls    = make([dynamic]Tool_Call, 0, len(choice.message.tool_calls), allocator),
	}
	for call in choice.message.tool_calls {
		if call.id == "" || call.function.name == "" || call.function.arguments == "" {
			chat_response_destroy(&response, allocator)
			return Chat_Response{}, .Invalid_Response
		}
		append(
			&response.toolCalls,
			Tool_Call {
				id = strings.clone(call.id, allocator),
				name = strings.clone(call.function.name, allocator),
				arguments = strings.clone(call.function.arguments, allocator),
			},
		)
	}
	if response.content == "" && len(response.toolCalls) == 0 {
		chat_response_destroy(&response, allocator)
		return Chat_Response{}, .Invalid_Response
	}
	return response, .None
}

parse_openai_error_message :: proc(body: string, allocator := context.allocator) -> string {
	wire: OpenAI_Error_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return ""
	}

	if wire.error.message == "" {
		return ""
	}

	return strings.clone(wire.error.message, allocator)
}

parse_openai_stream_event :: proc(
	event: string,
	callbackState: Chat_Stream_Callback_State,
) -> (
	stop: bool,
	err: AI_Error,
) {
	if event == "" || event == "[DONE]" {
		return event == "[DONE]", .None
	}

	wire: OpenAI_Stream_Response
	decodeErr := json.unmarshal_string(event, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return false, .Invalid_Response
	}

	if len(wire.choices) == 0 {
		return false, .Invalid_Response
	}

	choice := wire.choices[0]
	toolState := cast(^OpenAI_Stream_Tool_State)callbackState.parserData
	if len(choice.delta.tool_calls) > 0 {
		if toolState == nil {
			return false, .Invalid_Response
		}
		for call in choice.delta.tool_calls {
			if call.index < 0 {
				return false, .Invalid_Response
			}
			for len(toolState.calls) <= call.index {
				append(&toolState.calls, Tool_Call{})
			}
			accumulated := &toolState.calls[call.index]
			if call.id != "" {
				if accumulated.id != "" {
					delete(accumulated.id)
				}
				accumulated.id = strings.clone(call.id)
			}
			if call.function.name != "" {
				if accumulated.name != "" {
					delete(accumulated.name)
				}
				accumulated.name = strings.clone(call.function.name)
			}
			if call.function.arguments != "" {
				arguments := strings.concatenate({accumulated.arguments, call.function.arguments})
				if accumulated.arguments != "" {
					delete(accumulated.arguments)
				}
				accumulated.arguments = arguments
			}
		}
	}

	if choice.finish_reason == "tool_calls" {
		if toolState == nil || len(toolState.calls) == 0 {
			return false, .Invalid_Response
		}
		for call in toolState.calls {
			if call.id == "" || call.name == "" || call.arguments == "" {
				return false, .Invalid_Response
			}
			if !chat_stream_callback_call(
				callbackState,
				Chat_Stream_Delta{toolCall = call, hasToolCall = true, toolCallDone = true},
			) {
				return true, .None
			}
		}
	}

	content := choice.delta.content
	if content == "" {
		content = choice.delta.reasoning
	}

	if content == "" && choice.finish_reason == "" {
		return false, .None
	}

	return !chat_stream_callback_call(
			callbackState,
			Chat_Stream_Delta {
				content = content,
				model = wire.model,
				finishReason = choice.finish_reason,
				done = choice.finish_reason != "",
			},
		),
		.None
}

openai_stream_tool_state_destroy :: proc(state: ^OpenAI_Stream_Tool_State) {
	for &call in state.calls {
		tool_call_destroy(&call)
	}
	delete(state.calls)
	state^ = {}
}

parse_openai_models_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	wire: OpenAI_Models_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return [dynamic]string{}, .Invalid_Response
	}

	models: [dynamic]string
	for model in wire.data {
		if model.id != "" {
			append(&models, strings.clone(model.id, allocator))
		}
	}

	return models, .None
}
