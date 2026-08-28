package ai

import json "core:encoding/json"
import "core:strings"

import http "../http"

OpenAI_Message :: struct {
	role:         string,
	content:      string `json:"content,omitempty"`,
	tool_calls:   []OpenAI_Tool_Call `json:"tool_calls,omitempty"`,
	tool_call_id: string `json:"tool_call_id,omitempty"`,
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
	index:    int `json:"index,omitempty"`,
	id:       string,
	type:     string,
	function: OpenAI_Tool_Call_Function,
}

OpenAI_Chat_Request :: struct {
	model:       string,
	messages:    [dynamic]OpenAI_Message,
	stream:      bool,
	temperature: f32,
	max_tokens:  int,
	tools:       []OpenAI_Tool `json:"tools,omitempty"`,
}

OpenAI_Chat_Choice :: struct {
	message:       OpenAI_Message,
	delta:         OpenAI_Message,
	finish_reason: string,
}

OpenAI_Usage :: struct {
	prompt_tokens:     int,
	completion_tokens: int,
}

OpenAI_Chat_Response :: struct {
	id:      string,
	model:   string,
	choices: []OpenAI_Chat_Choice,
	usage:   OpenAI_Usage,
}

OpenAI_Embedding_Request :: struct {
	model:      string,
	input:      []string,
	dimensions: int `json:"dimensions,omitempty"`,
}

OpenAI_Embedding_Data :: struct {
	embedding: []f32,
}

OpenAI_Embedding_Response :: struct {
	model: string,
	data:  []OpenAI_Embedding_Data,
	usage: OpenAI_Usage,
}

OpenAI_Model :: struct {
	id: string,
}

OpenAI_Models_Response :: struct {
	data: []OpenAI_Model,
}

OpenAI_Error_Body :: struct {
	message: string,
}

OpenAI_Error_Response :: struct {
	error: OpenAI_Error_Body,
}

OpenAI_Stream_Tool_Call :: struct {
	id:        string,
	name:      string,
	arguments: string,
}

OpenAI_Stream_Tool_State :: struct {
	calls: [dynamic]OpenAI_Stream_Tool_Call,
}

destroy_openai_stream_tool_state :: proc(state: ^OpenAI_Stream_Tool_State) {
	for &call in state.calls {
		if call.id != "" {
			delete(call.id)
		}
		if call.name != "" {
			delete(call.name)
		}
		if call.arguments != "" {
			delete(call.arguments)
		}
	}
	delete(state.calls)
}

build_openai_chat_request :: proc(
	request: Chat_Request,
	allocator := context.temp_allocator,
) -> OpenAI_Chat_Request {
	wire := OpenAI_Chat_Request {
		model       = request.model,
		messages    = make([dynamic]OpenAI_Message, 0, len(request.messages), allocator),
		stream      = false,
		temperature = request.temperature,
		max_tokens  = request.maxTokens,
		tools       = make([]OpenAI_Tool, len(request.tools), allocator),
	}
	for message in request.messages {
		if message.role == .Tool {
			for result in message.toolResults {
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
			role       = message_role_to_string(message.role),
			content    = message.content,
			tool_calls = make([]OpenAI_Tool_Call, len(message.toolCalls), allocator),
		}
		for call, index in message.toolCalls {
			wireMessage.tool_calls[index] = OpenAI_Tool_Call {
				id = call.id,
				type = "function",
				function = OpenAI_Tool_Call_Function{name = call.name, arguments = call.arguments},
			}
		}
		append(&wire.messages, wireMessage)
	}
	for tool, index in request.tools {
		parameters, parseErr := json.parse_string(tool.parametersJSON, allocator = allocator)
		if parseErr != .None {
			parameters = json.Null(nil)
		}
		wire.tools[index] = OpenAI_Tool {
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

build_openai_embedding_request :: proc(
	request: Embedding_Batch_Request,
) -> OpenAI_Embedding_Request {
	return OpenAI_Embedding_Request {
		model = request.model,
		input = request.inputs,
		dimensions = request.options.dimensions,
	}
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
	if decodeErr != nil || wire.model == "" || len(wire.choices) == 0 {
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
		if call.id == "" ||
		   call.type != "function" ||
		   call.function.name == "" ||
		   call.function.arguments == "" {
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

parse_openai_embedding_response :: proc(
	body: string,
	expectedCount: int,
	allocator := context.allocator,
) -> (
	Embedding_Batch_Response,
	AI_Error,
) {
	wire: OpenAI_Embedding_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil ||
	   wire.model == "" ||
	   expectedCount <= 0 ||
	   len(wire.data) != expectedCount {
		return Embedding_Batch_Response{}, .Invalid_Response
	}
	response := Embedding_Batch_Response {
		model           = strings.clone(wire.model, allocator),
		embeddings      = make([dynamic][dynamic]f32, 0, expectedCount, allocator),
		inputTokenCount = wire.usage.prompt_tokens,
	}
	for entry in wire.data {
		if len(entry.embedding) == 0 {
			embedding_batch_response_destroy(&response, allocator)
			return Embedding_Batch_Response{}, .Invalid_Response
		}
		vector := make([dynamic]f32, 0, len(entry.embedding), allocator)
		for value in entry.embedding {
			append(&vector, value)
		}
		append(&response.embeddings, vector)
	}
	return response, .None
}

parse_openai_models_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	wire: OpenAI_Models_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return [dynamic]Model{}, .Invalid_Response
	}
	models: [dynamic]Model
	for model in wire.data {
		if model.id == "" {
			continue
		}
		entry := Model {
			name = strings.clone(model.id, allocator),
		}
		if model_name_indicates_embedding(model.id) {
			append(&entry.capabilities, strings.clone("embedding", allocator))
		} else {
			append(&entry.capabilities, strings.clone("completion", allocator))
			append(&entry.capabilities, strings.clone("tools", allocator))
		}
		append(&models, entry)
	}
	return models, .None
}

parse_openai_error_message :: proc(body: string, allocator := context.allocator) -> string {
	wire: OpenAI_Error_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil || wire.error.message == "" {
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
		return false, .None
	}
	wire: OpenAI_Chat_Response
	decodeErr := json.unmarshal_string(event, &wire, allocator = context.temp_allocator)
	if decodeErr != nil || len(wire.choices) == 0 {
		return false, .Invalid_Response
	}
	choice := wire.choices[0]
	toolState := cast(^OpenAI_Stream_Tool_State)callbackState.parserData
	if len(choice.delta.tool_calls) > 0 {
		if toolState == nil {
			return false, .Invalid_Response
		}
		for call in choice.delta.tool_calls {
			for len(toolState.calls) <= call.index {
				append(&toolState.calls, OpenAI_Stream_Tool_Call{})
			}
			pending := &toolState.calls[call.index]
			if call.id != "" {
				if pending.id != "" {
					delete(pending.id)
				}
				pending.id = strings.clone(call.id)
			}
			if call.function.name != "" {
				combinedName := strings.concatenate({pending.name, call.function.name})
				if pending.name != "" {
					delete(pending.name)
				}
				pending.name = combinedName
			}
			if call.function.arguments != "" {
				combinedArguments := strings.concatenate(
					{pending.arguments, call.function.arguments},
				)
				if pending.arguments != "" {
					delete(pending.arguments)
				}
				pending.arguments = combinedArguments
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
			toolCall := Tool_Call {
				id        = strings.clone(call.id),
				name      = strings.clone(call.name),
				arguments = strings.clone(call.arguments),
			}
			keepStreaming := chat_stream_callback_call(
				callbackState,
				Chat_Stream_Delta{toolCall = toolCall, hasToolCall = true, toolCallDone = true},
			)
			tool_call_destroy(&toolCall)
			if !keepStreaming {
				return true, .None
			}
		}
	}
	usage := Chat_Usage{}
	if wire.usage.prompt_tokens > 0 {
		usage.inputTokens = wire.usage.prompt_tokens
		usage.hasInputTokens = true
	}
	if wire.usage.completion_tokens > 0 {
		usage.outputTokens = wire.usage.completion_tokens
		usage.hasOutputTokens = true
	}
	return !chat_stream_callback_call(
			callbackState,
			Chat_Stream_Delta {
				content = choice.delta.content,
				model = wire.model,
				finishReason = choice.finish_reason,
				done = choice.finish_reason != "",
				usage = usage,
			},
		),
		.None
}

send_openai_chat_completion :: proc(
	client: Client,
	request: Chat_Request,
) -> (
	Chat_Response,
	AI_Error,
) {
	target, ok := openai_endpoint_target(client.iface.endpoint, OPENAI_CHAT_PATH)
	if !ok {
		return Chat_Response{}, .Invalid_Request
	}
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	append_openai_auth_headers(&extraHeaders, client.apiKey)
	body, status, err := do_json_post(target, build_openai_chat_request(request), extraHeaders[:])
	if err != .None {
		return Chat_Response{}, err
	}
	defer if body != "" {delete(body)}
	if http.status_is_success(status) {
		return parse_openai_chat_response(body)
	}
	return Chat_Response{}, map_status_to_error(status)
}

send_openai_embeddings :: proc(
	client: Client,
	request: Embedding_Batch_Request,
	allocator := context.allocator,
) -> (
	Embedding_Batch_Response,
	AI_Error,
) {
	target, ok := openai_endpoint_target(client.iface.endpoint, OPENAI_EMBED_PATH)
	if !ok {
		return Embedding_Batch_Response{}, .Invalid_Request
	}
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	append_openai_auth_headers(&extraHeaders, client.apiKey)
	body, status, err := do_json_post(
		target,
		build_openai_embedding_request(request),
		extraHeaders[:],
	)
	if err != .None {
		return Embedding_Batch_Response{}, err
	}
	defer if body != "" {delete(body)}
	if http.status_is_success(status) {
		return parse_openai_embedding_response(body, len(request.inputs), allocator)
	}
	return Embedding_Batch_Response{}, map_status_to_error(status)
}

send_openai_chat_completion_stream :: proc(
	client: Client,
	request: Chat_Request,
	callbackState: Chat_Stream_Callback_State,
) -> AI_Error {
	target, ok := openai_endpoint_target(client.iface.endpoint, OPENAI_CHAT_PATH)
	if !ok {
		return .Invalid_Request
	}
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	append_openai_auth_headers(&extraHeaders, client.apiKey)
	toolState: OpenAI_Stream_Tool_State
	defer destroy_openai_stream_tool_state(&toolState)
	streamCallbackState := callbackState
	streamCallbackState.parserData = rawptr(&toolState)
	body, status, err := do_json_post_stream(
		target,
		build_openai_chat_stream_request(request),
		extraHeaders[:],
		streamCallbackState,
		parse_openai_stream_event,
		parse_sse_stream_chunk,
	)
	defer if body != "" {delete(body)}
	if err != .None {
		return err
	}
	if !http.status_is_success(status) {
		return map_status_to_error(status)
	}
	return .None
}

list_openai_models :: proc(
	client: Client,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	target, ok := openai_endpoint_target(client.iface.endpoint, OPENAI_MODELS_PATH)
	if !ok {
		return [dynamic]Model{}, .Invalid_Request
	}
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	append_openai_auth_headers(&extraHeaders, client.apiKey)
	append(&extraHeaders, [2]string{"Content-Type", "application/json"})
	body, status, err := do_json_get(target, extraHeaders[:])
	if err != .None {
		return [dynamic]Model{}, err
	}
	defer if body != "" {delete(body)}
	if http.status_is_success(status) {
		return parse_openai_models_response(body, allocator)
	}
	return [dynamic]Model{}, map_status_to_error(status)
}

openai_endpoint_target :: proc(endpoint: http.URL, pathSuffix: string) -> (string, bool) {
	if endpoint.host == "" || endpoint.raw == "" {
		return "", false
	}
	if strings.has_suffix(strings.trim_right(endpoint.raw, "/"), "/v1") {
		return compose_endpoint_target(endpoint, pathSuffix)
	}
	return compose_endpoint_target(
		endpoint,
		strings.concatenate({"/v1", pathSuffix}, context.temp_allocator),
	)
}

append_openai_auth_headers :: proc(extraHeaders: ^[dynamic][2]string, apiKey: string) {
	if apiKey == "" {
		return
	}
	authorization := strings.concatenate({"Bearer ", apiKey}, context.temp_allocator)
	append(extraHeaders, [2]string{"Authorization", authorization})
}
