package ai

import json "core:encoding/json"
import "core:strings"

OpenAI_Message :: struct {
	role:    string,
	content: string,
}

OpenAI_Chat_Request :: struct {
	model:       string,
	messages:    []OpenAI_Message,
	temperature: f32,
	max_tokens:  int,
	stream:      bool,
}

OpenAI_Choice_Message :: struct {
	role:    string,
	content: string,
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
	role:      string,
	content:   string,
	reasoning: string,
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
		messages    = make([]OpenAI_Message, len(request.messages), allocator),
		temperature = request.temperature,
		max_tokens  = request.maxTokens,
		stream      = false,
	}

	for msg, idx in request.messages {
		wire.messages[idx] = OpenAI_Message {
			role    = message_role_to_string(msg.role),
			content = msg.content,
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
	return Chat_Response {
			content = strings.clone(choice.message.content, allocator),
			model = strings.clone(wire.model, allocator),
			finishReason = strings.clone(choice.finish_reason, allocator),
		},
		.None
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
