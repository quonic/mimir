package ai

import json "core:encoding/json"
import "core:fmt"
import "core:strings"

import http "../http"

Ollama_Message :: struct {
	role:       string,
	content:    string,
	tool_calls: []Ollama_Tool_Call,
}

Ollama_Function :: struct {
	name:        string,
	description: string,
	parameters:  json.Value,
	arguments:   json.Value,
}

Ollama_Tool :: struct {
	type:     string,
	function: Ollama_Function,
}

Ollama_Tool_Call :: struct {
	function: Ollama_Function,
}

Ollama_Stream_Tool_State :: struct {
	nextCallIndex: int,
}

Ollama_Options :: struct {
	temperature: f32,
	num_predict: int,
}

Ollama_Chat_Request :: struct {
	model:    string,
	messages: [dynamic]Ollama_Message,
	stream:   bool,
	options:  Ollama_Options,
	tools:    []Ollama_Tool,
}

Ollama_Chat_Response :: struct {
	model:             string,
	message:           Ollama_Message,
	done:              bool,
	done_reason:       string,
	prompt_eval_count: json.Value,
	eval_count:        json.Value,
}

Ollama_Model :: struct {
	name:         string,
	capabilities: []string,
}

Ollama_Models_Response :: struct {
	models: []Ollama_Model,
}

Ollama_Show_Request :: struct {
	model: string,
}

Ollama_Show_Response :: struct {
	model_info: json.Value,
}

Ollama_Embedding_Response :: struct {
	model:             string,
	embeddings:        [][]f32,
	total_duration:    i64,
	load_duration:     i64,
	prompt_eval_count: int,
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
		messages = make([dynamic]Ollama_Message, 0, len(request.messages), allocator),
		stream = false,
		options = Ollama_Options {
			temperature = request.temperature,
			num_predict = request.maxTokens,
		},
		tools = make([]Ollama_Tool, len(request.tools), allocator),
	}

	for msg in request.messages {
		if msg.role == .Tool {
			for result in msg.toolResults {
				append(&wire.messages, Ollama_Message{role = "tool", content = result.content})
			}
			continue
		}

		wireMessage := Ollama_Message {
			role       = message_role_to_string(msg.role),
			content    = msg.content,
			tool_calls = make([]Ollama_Tool_Call, len(msg.toolCalls), allocator),
		}
		for call, index in msg.toolCalls {
			arguments, parseErr := json.parse_string(call.arguments, allocator = allocator)
			if parseErr != .None {
				arguments = json.Null(nil)
			}
			wireMessage.tool_calls[index] = Ollama_Tool_Call {
				function = Ollama_Function{name = call.name, arguments = arguments},
			}
		}
		append(&wire.messages, wireMessage)
	}
	for tool, index in request.tools {
		parameters, parseErr := json.parse_string(tool.parametersJSON, allocator = allocator)
		if parseErr != .None {
			parameters = json.Null(nil)
		}
		wire.tools[index] = Ollama_Tool {
			type = "function",
			function = Ollama_Function {
				name = tool.name,
				description = tool.description,
				parameters = parameters,
			},
		}
	}

	return wire
}

build_ollama_chat_stream_request :: proc(request: Chat_Request) -> Ollama_Chat_Request {
	wire := build_ollama_chat_request(request)
	wire.stream = true
	return wire
}

build_ollama_embedding_request :: proc(
	request: Embedding_Batch_Request,
	allocator := context.temp_allocator,
) -> json.Value {
	wire := make(map[string]json.Value, allocator)
	wire["model"] = json.String(request.model)
	if len(request.inputs) == 1 {
		wire["input"] = json.String(request.inputs[0])
	} else {
		inputs := make([dynamic]json.Value, 0, len(request.inputs), allocator)
		for input in request.inputs {
			append(&inputs, json.String(input))
		}
		wire["input"] = json.Array(inputs)
	}
	if request.options.hasDimensions && request.options.dimensions > 0 {
		wire["dimensions"] = json.Integer(i64(request.options.dimensions))
	}
	if request.options.hasOllamaTruncate {
		wire["truncate"] = json.Boolean(request.options.ollamaTruncate)
	}
	if request.options.hasOllamaKeepAlive {
		wire["keep_alive"] = json.String(request.options.ollamaKeepAlive)
	}
	if request.options.hasOllamaOptions {
		wire["options"] = request.options.ollamaOptions
	}

	return json.Object(wire)
}

parse_ollama_embedding_response :: proc(
	body: string,
	expectedCount: int,
	allocator := context.allocator,
) -> (
	Embedding_Batch_Response,
	AI_Error,
) {
	wire: Ollama_Embedding_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil ||
	   wire.model == "" ||
	   expectedCount <= 0 ||
	   len(wire.embeddings) != expectedCount ||
	   wire.prompt_eval_count < 0 {
		return Embedding_Batch_Response{}, .Invalid_Response
	}

	response := Embedding_Batch_Response {
		model           = strings.clone(wire.model, allocator),
		embeddings      = make([dynamic][dynamic]f32, 0, expectedCount, allocator),
		inputTokenCount = wire.prompt_eval_count,
		totalDuration   = wire.total_duration,
		loadDuration    = wire.load_duration,
	}
	for embedding in wire.embeddings {
		if len(embedding) == 0 {
			embedding_batch_response_destroy(&response, allocator)
			return Embedding_Batch_Response{}, .Invalid_Response
		}

		vector := make([dynamic]f32, 0, len(embedding), allocator)
		for value in embedding {
			append(&vector, value)
		}
		append(&response.embeddings, vector)
	}

	return response, .None
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

	response := Chat_Response {
		content      = strings.clone(wire.message.content, allocator),
		model        = strings.clone(wire.model, allocator),
		finishReason = strings.clone(wire.done_reason, allocator),
		toolCalls    = make([dynamic]Tool_Call, 0, len(wire.message.tool_calls), allocator),
	}
	for call, index in wire.message.tool_calls {
		if call.function.name == "" {
			chat_response_destroy(&response, allocator)
			return Chat_Response{}, .Invalid_Response
		}
		arguments, unparseErr := json.unparse(call.function.arguments, allocator = allocator)
		if unparseErr != nil {
			chat_response_destroy(&response, allocator)
			return Chat_Response{}, .Invalid_Response
		}
		append(
			&response.toolCalls,
			Tool_Call {
				id = ollama_tool_call_id(index, allocator),
				name = strings.clone(call.function.name, allocator),
				arguments = arguments,
			},
		)
	}
	if response.content == "" && len(response.toolCalls) == 0 {
		chat_response_destroy(&response, allocator)
		return Chat_Response{}, .Invalid_Response
	}
	return response, .None
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

	toolState := cast(^Ollama_Stream_Tool_State)callbackState.parserData
	if len(wire.message.tool_calls) > 0 {
		if toolState == nil {
			return false, .Invalid_Response
		}
		for call in wire.message.tool_calls {
			if call.function.name == "" {
				return false, .Invalid_Response
			}
			arguments, unparseErr := json.unparse(call.function.arguments)
			if unparseErr != nil {
				return false, .Invalid_Response
			}
			toolCall := Tool_Call {
				id        = ollama_tool_call_id(toolState.nextCallIndex),
				name      = strings.clone(call.function.name),
				arguments = arguments,
			}
			toolState.nextCallIndex += 1
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

	if wire.message.content == "" && len(wire.message.tool_calls) == 0 && !wire.done {
		return false, .None
	}

	usage := ollama_chat_usage(wire.prompt_eval_count, wire.eval_count)
	if !wire.done {
		usage = {}
	}
	return !chat_stream_callback_call(
			callbackState,
			Chat_Stream_Delta {
				content = wire.message.content,
				model = wire.model,
				finishReason = wire.done_reason,
				done = wire.done,
				usage = usage,
			},
		),
		.None
}

ollama_chat_usage :: proc(inputValue, outputValue: json.Value) -> Chat_Usage {
	usage: Chat_Usage
	if input, ok := inputValue.(json.Integer); ok && input >= 0 {
		usage.inputTokens = int(input)
		usage.hasInputTokens = true
	}
	if output, ok := outputValue.(json.Integer); ok && output >= 0 {
		usage.outputTokens = int(output)
		usage.hasOutputTokens = true
	}
	return usage
}

ollama_tool_call_id :: proc(index: int, allocator := context.allocator) -> string {
	return strings.clone(fmt.tprintf("ollama-%d", index), allocator)
}

parse_ollama_models_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	wire: Ollama_Models_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return [dynamic]Model{}, .Invalid_Response
	}

	models: [dynamic]Model
	for model in wire.models {
		if model.name != "" {
			entry := Model {
				name = strings.clone(model.name, allocator),
			}
			for capability in model.capabilities {
				append(&entry.capabilities, strings.clone(capability, allocator))
			}
			append(&models, entry)
		}
	}

	return models, .None
}

get_ollama_model_context_window :: proc(client: Client, model: string) -> (int, AI_Error) {
	if client.iface.type != .Ollama || model == "" {
		return 0, .Invalid_Request
	}
	target, ok := compose_endpoint_target(client.iface.endpoint, OLLAMA_SHOW_PATH)
	if !ok {
		return 0, .Invalid_Request
	}

	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_post(
		target,
		Ollama_Show_Request{model = model},
		extraHeaders[:],
	)
	if errKind != .None {
		return 0, errKind
	}
	defer if body != "" {delete(body)}
	if !http.status_is_success(status) {
		_ = parse_ollama_error_message(body)
		return 0, map_status_to_error(status)
	}
	return parse_ollama_model_context_window(body)
}

parse_ollama_model_context_window :: proc(body: string) -> (int, AI_Error) {
	wire: Ollama_Show_Response
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return 0, .Invalid_Response
	}
	modelInfo, ok := wire.model_info.(json.Object)
	if !ok {
		return 0, .None
	}
	for key, value in modelInfo {
		if !strings.has_suffix(key, ".context_length") {
			continue
		}
		if contextLength, contextLengthOK := value.(json.Integer);
		   contextLengthOK && contextLength > 0 {
			return int(contextLength), .None
		}
	}
	return 0, .None
}
