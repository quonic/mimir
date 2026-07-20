package ai

import json "core:encoding/json"
import "core:strings"

Anthropic_Content_Block :: struct {
	type: string,
	text: string,
}

Anthropic_Message :: struct {
	role:    string,
	content: string,
}

Anthropic_Request :: struct {
	model:      string,
	messages:   []Anthropic_Message,
	max_tokens: int,
	stream:     bool,
}

Anthropic_Response :: struct {
	model:       string,
	content:     []Anthropic_Content_Block,
	stop_reason: string,
}

Anthropic_Stream_Content_Delta :: struct {
	type: string,
	text: string,
}

Anthropic_Stream_Message_Delta :: struct {
	stop_reason: string,
}

Anthropic_Stream_Response :: struct {
	type:    string,
	delta:   struct {
		type:        string,
		text:        string,
		stop_reason: string,
	},
	message: struct {
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
	}

	for msg, idx in request.messages {
		role := message_role_to_string(msg.role)
		if role == "system" {
			role = "user"
		}

		wire.messages[idx] = Anthropic_Message {
			role    = role,
			content = msg.content,
		}
	}

	return wire
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

	for block in wire.content {
		if block.type == "text" {
			return Chat_Response {
					content = strings.clone(block.text, allocator),
					model = strings.clone(wire.model, allocator),
					finishReason = strings.clone(wire.stop_reason, allocator),
				},
				.None
		}
	}

	return Chat_Response{}, .Invalid_Response
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
	case "content_block_delta":
		if wire.delta.type == "text_delta" && wire.delta.text != "" {
			return !chat_stream_callback_call(
					callbackState,
					Chat_Stream_Delta{content = wire.delta.text},
				),
				.None
		}
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
