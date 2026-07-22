package ai

import json "core:encoding/json"
import "core:strings"

Anthropic_Content_Block :: struct {
	type:  string,
	text:  string,
	id:    string,
	name:  string,
	input: json.Value,
}

Anthropic_Tool :: struct {
	name:         string,
	description:  string,
	input_schema: json.Value,
}

Anthropic_Message :: struct {
	role:    string,
	content: json.Value,
}

Anthropic_Request :: struct {
	model:      string,
	messages:   []Anthropic_Message,
	max_tokens: int,
	stream:     bool,
	tools:      []Anthropic_Tool,
}

Anthropic_Response :: struct {
	model:       string,
	content:     []Anthropic_Content_Block,
	stop_reason: string,
}

Anthropic_Stream_Content_Delta :: struct {
	type:         string,
	text:         string,
	partial_json: string,
}

Anthropic_Stream_Tool_Accumulator :: struct {
	call:   Tool_Call,
	active: bool,
}

Anthropic_Stream_Tool_State :: struct {
	calls: [dynamic]Anthropic_Stream_Tool_Accumulator,
}

Anthropic_Stream_Message_Delta :: struct {
	stop_reason: string,
}

Anthropic_Stream_Response :: struct {
	type:          string,
	index:         int,
	content_block: Anthropic_Content_Block,
	delta:         struct {
		type:         string,
		text:         string,
		partial_json: string,
		stop_reason:  string,
	},
	message:       struct {
		model: string,
	},
}

Anthropic_Model :: struct {
	id: string,
}

Anthropic_Models_Response :: struct {
	data: []Anthropic_Model,
}

Anthropic_Error_Detail :: struct {
	type:    string,
	message: string,
}

Anthropic_Error_Response :: struct {
	error: Anthropic_Error_Detail,
}

build_anthropic_request :: proc(
	request: Chat_Request,
	allocator := context.temp_allocator,
) -> Anthropic_Request {
	maxTokens := request.maxTokens
	if maxTokens <= 0 {
		maxTokens = 256
	}

	wire := Anthropic_Request {
		model      = request.model,
		messages   = make([]Anthropic_Message, len(request.messages), allocator),
		max_tokens = maxTokens,
		stream     = false,
		tools      = make([]Anthropic_Tool, len(request.tools), allocator),
	}

	for msg, idx in request.messages {
		role := message_role_to_string(msg.role)
		if role == "system" {
			role = "user"
		} else if role == "tool" {
			role = "user"
		}

		wire.messages[idx] = Anthropic_Message {
			role    = role,
			content = anthropic_message_content(msg, allocator),
		}
	}
	for tool, idx in request.tools {
		inputSchema, parseErr := json.parse_string(tool.parametersJSON, allocator = allocator)
		if parseErr != .None {
			inputSchema = json.Null(nil)
		}
		wire.tools[idx] = Anthropic_Tool {
			name         = tool.name,
			description  = tool.description,
			input_schema = inputSchema,
		}
	}

	return wire
}

anthropic_message_content :: proc(
	msg: Message,
	allocator := context.temp_allocator,
) -> json.Value {
	if msg.role != .Assistant && msg.role != .Tool {
		return json.String(msg.content)
	}

	blockCount := len(msg.toolCalls) if msg.role == .Assistant else len(msg.toolResults)
	if blockCount == 0 {
		return json.String(msg.content)
	}

	blocks := make([dynamic]json.Value, 0, blockCount + 1, allocator)
	if msg.content != "" {
		textBlock := make(map[string]json.Value, allocator)
		textBlock["type"] = json.String("text")
		textBlock["text"] = json.String(msg.content)
		append(&blocks, json.Object(textBlock))
	}
	if msg.role == .Assistant {
		for call in msg.toolCalls {
			input, parseErr := json.parse_string(call.arguments, allocator = allocator)
			if parseErr != .None {
				input = json.Null(nil)
			}
			toolUseBlock := make(map[string]json.Value, allocator)
			toolUseBlock["type"] = json.String("tool_use")
			toolUseBlock["id"] = json.String(call.id)
			toolUseBlock["name"] = json.String(call.name)
			toolUseBlock["input"] = input
			append(&blocks, json.Object(toolUseBlock))
		}
	} else {
		for result in msg.toolResults {
			toolResultBlock := make(map[string]json.Value, allocator)
			toolResultBlock["type"] = json.String("tool_result")
			toolResultBlock["tool_use_id"] = json.String(result.toolCallID)
			toolResultBlock["content"] = json.String(result.content)
			if result.isError {
				toolResultBlock["is_error"] = json.Boolean(true)
			}
			append(&blocks, json.Object(toolResultBlock))
		}
	}
	return json.Array(blocks)
}

build_anthropic_stream_request :: proc(request: Chat_Request) -> Anthropic_Request {
	wire := build_anthropic_request(request)
	wire.stream = true
	return wire
}

parse_anthropic_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	Chat_Response,
	AI_Error,
) {
	wire: Anthropic_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return Chat_Response{}, .Invalid_Response
	}

	response := Chat_Response {
		model        = strings.clone(wire.model, allocator),
		finishReason = strings.clone(wire.stop_reason, allocator),
		toolCalls    = make([dynamic]Tool_Call, 0, len(wire.content), allocator),
	}
	for block in wire.content {
		if block.type == "text" && response.content == "" {
			response.content = strings.clone(block.text, allocator)
		} else if block.type == "tool_use" {
			if block.id == "" || block.name == "" {
				chat_response_destroy(&response, allocator)
				return Chat_Response{}, .Invalid_Response
			}
			arguments, unparseErr := json.unparse(block.input, allocator = allocator)
			if unparseErr != nil {
				chat_response_destroy(&response, allocator)
				return Chat_Response{}, .Invalid_Response
			}
			append(
				&response.toolCalls,
				Tool_Call {
					id = strings.clone(block.id, allocator),
					name = strings.clone(block.name, allocator),
					arguments = arguments,
				},
			)
		}
	}
	if response.content == "" && len(response.toolCalls) == 0 {
		chat_response_destroy(&response, allocator)
		return Chat_Response{}, .Invalid_Response
	}
	return response, .None
}

parse_anthropic_error_message :: proc(body: string, allocator := context.allocator) -> string {
	wire: Anthropic_Error_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return ""
	}

	if wire.error.message == "" {
		return ""
	}

	return strings.clone(wire.error.message, allocator)
}

parse_anthropic_stream_event :: proc(
	event: string,
	callbackState: Chat_Stream_Callback_State,
) -> (
	stop: bool,
	err: AI_Error,
) {
	if event == "" {
		return false, .None
	}

	wire: Anthropic_Stream_Response
	decodeErr := json.unmarshal_string(event, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return false, .Invalid_Response
	}

	switch wire.type {
	case "message_start":
		if wire.message.model != "" {
			return !chat_stream_callback_call(
					callbackState,
					Chat_Stream_Delta{model = wire.message.model},
				),
				.None
		}
	case "content_block_start":
		if wire.content_block.type != "tool_use" {
			return false, .None
		}
		if wire.index < 0 || wire.content_block.id == "" || wire.content_block.name == "" {
			return false, .Invalid_Response
		}
		toolState := cast(^Anthropic_Stream_Tool_State)callbackState.parserData
		if toolState == nil {
			return false, .Invalid_Response
		}
		for len(toolState.calls) <= wire.index {
			append(&toolState.calls, Anthropic_Stream_Tool_Accumulator{})
		}
		accumulator := &toolState.calls[wire.index]
		if accumulator.active {
			return false, .Invalid_Response
		}
		accumulator.call.id = strings.clone(wire.content_block.id)
		accumulator.call.name = strings.clone(wire.content_block.name)
		accumulator.active = true
	case "content_block_delta":
		if wire.delta.type == "text_delta" && wire.delta.text != "" {
			return !chat_stream_callback_call(
					callbackState,
					Chat_Stream_Delta{content = wire.delta.text},
				),
				.None
		}
		if wire.delta.type == "input_json_delta" {
			toolState := cast(^Anthropic_Stream_Tool_State)callbackState.parserData
			if toolState == nil || wire.index < 0 || wire.index >= len(toolState.calls) {
				return false, .Invalid_Response
			}
			accumulator := &toolState.calls[wire.index]
			if !accumulator.active {
				return false, .Invalid_Response
			}
			if wire.delta.partial_json != "" {
				arguments := strings.concatenate(
					{accumulator.call.arguments, wire.delta.partial_json},
				)
				if accumulator.call.arguments != "" {
					delete(accumulator.call.arguments)
				}
				accumulator.call.arguments = arguments
			}
		}
	case "content_block_stop":
		toolState := cast(^Anthropic_Stream_Tool_State)callbackState.parserData
		if toolState == nil || wire.index < 0 || wire.index >= len(toolState.calls) {
			return false, .None
		}
		accumulator := &toolState.calls[wire.index]
		if !accumulator.active {
			return false, .None
		}
		if accumulator.call.arguments == "" {
			accumulator.call.arguments = strings.clone("{}")
		}
		_, parseErr := json.parse_string(accumulator.call.arguments)
		if parseErr != .None {
			return false, .Invalid_Response
		}
		accumulator.active = false
		return !chat_stream_callback_call(
				callbackState,
				Chat_Stream_Delta {
					toolCall = accumulator.call,
					hasToolCall = true,
					toolCallDone = true,
				},
			),
			.None
	case "message_delta":
		if wire.delta.stop_reason != "" {
			return !chat_stream_callback_call(
					callbackState,
					Chat_Stream_Delta{finishReason = wire.delta.stop_reason, done = true},
				),
				.None
		}
	case "message_stop":
		return !chat_stream_callback_call(callbackState, Chat_Stream_Delta{done = true}), .None
	}

	return false, .None
}

anthropic_stream_tool_state_destroy :: proc(state: ^Anthropic_Stream_Tool_State) {
	for &accumulator in state.calls {
		tool_call_destroy(&accumulator.call)
	}
	delete(state.calls)
	state^ = {}
}

parse_anthropic_models_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	wire: Anthropic_Models_Response
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
