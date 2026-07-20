package ai

import json "core:encoding/json"
import "core:strings"

Ollama_Message :: struct {
	role:    string,
	content: string,
}

Ollama_Options :: struct {
	temperature: f32,
	num_predict: int,
}

Ollama_Chat_Request :: struct {
	model:    string,
	messages: []Ollama_Message,
	stream:   bool,
	options:  Ollama_Options,
}

Ollama_Chat_Response :: struct {
	model:       string,
	message:     Ollama_Message,
	done:        bool,
	done_reason: string,
}

Ollama_Model :: struct {
	name: string,
}

Ollama_Models_Response :: struct {
	models: []Ollama_Model,
}

Ollama_Error_Response :: struct {
	error: string,
}

build_ollama_chat_request :: proc(
	request: Chat_Request,
	allocator := context.temp_allocator,
) -> Ollama_Chat_Request {
	wire := Ollama_Chat_Request {
		model = request.model,
		messages = make([]Ollama_Message, len(request.messages), allocator),
		stream = false,
		options = Ollama_Options {
			temperature = request.temperature,
			num_predict = request.maxTokens,
		},
	}

	for msg, idx in request.messages {
		wire.messages[idx] = Ollama_Message {
			role    = message_role_to_string(msg.role),
			content = msg.content,
		}
	}

	return wire
}

build_ollama_chat_stream_request :: proc(request: Chat_Request) -> Ollama_Chat_Request {
	wire := build_ollama_chat_request(request)
	wire.stream = true
	return wire
}

parse_ollama_chat_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	Chat_Response,
	AI_Error,
) {
	wire: Ollama_Chat_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return Chat_Response{}, .Invalid_Response
	}

	if wire.message.content == "" {
		return Chat_Response{}, .Invalid_Response
	}

	return Chat_Response {
			content = strings.clone(wire.message.content, allocator),
			model = strings.clone(wire.model, allocator),
			finishReason = strings.clone(wire.done_reason, allocator),
		},
		.None
}

parse_ollama_error_message :: proc(body: string, allocator := context.allocator) -> string {
	wire: Ollama_Error_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return ""
	}

	if wire.error == "" {
		return ""
	}

	return strings.clone(wire.error, allocator)
}

parse_ollama_stream_event :: proc(
	event: string,
	callbackState: Chat_Stream_Callback_State,
) -> (
	stop: bool,
	err: AI_Error,
) {
	if event == "" {
		return false, .None
	}

	wire: Ollama_Chat_Response
	decodeErr := json.unmarshal_string(event, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return false, .Invalid_Response
	}

	if wire.message.content == "" && !wire.done {
		return false, .None
	}

	return !chat_stream_callback_call(
			callbackState,
			Chat_Stream_Delta {
				content = wire.message.content,
				model = wire.model,
				finishReason = wire.done_reason,
				done = wire.done,
			},
		),
		.None
}

parse_ollama_models_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	wire: Ollama_Models_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return [dynamic]string{}, .Invalid_Response
	}

	models: [dynamic]string
	for model in wire.models {
		if model.name != "" {
			append(&models, strings.clone(model.name, allocator))
		}
	}

	return models, .None
}
