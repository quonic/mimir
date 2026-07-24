package ai

import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:strconv"
import "core:strings"

import http "../http"
import httpClient "../http/client"

OPENAI_CHAT_PATH :: "/chat/completions"
OPENAI_EMBEDDINGS_PATH :: "/embeddings"
OPENAI_MODELS_PATH :: "/models"
ANTHROPIC_MESSAGES_PATH :: "/messages"
ANTHROPIC_MODELS_PATH :: "/models"
ANTHROPIC_VERSION :: "2023-06-01"
OLLAMA_CHAT_PATH :: "/api/chat"
OLLAMA_EMBED_PATH :: "/api/embed"
OLLAMA_MODELS_PATH :: "/api/tags"
OLLAMA_SHOW_PATH :: "/api/show"

send_chat_completion :: proc(client: Client, request: Chat_Request) -> (Chat_Response, AI_Error) {
	if request.model == "" || len(request.messages) == 0 {
		return Chat_Response{}, .Invalid_Request
	}
	if !model_supported(client.iface, request.model) {
		return Chat_Response{}, .Unsupported_Model
	}

	if client.iface.type == .OpenAI {
		return send_openai_chat_completion(client, request)
	}
	if client.iface.type == .Anthropic {
		return send_anthropic_chat_completion(client, request)
	}
	if client.iface.type == .Ollama {
		return send_ollama_chat_completion(client, request)
	}

	return Chat_Response{}, .Unsupported_Interface
}

send_embedding :: proc(
	client: Client,
	request: Embedding_Request,
	allocator := context.allocator,
) -> (
	Embedding_Response,
	AI_Error,
) {
	batch, err := send_embeddings(
		client,
		Embedding_Batch_Request {
			model = request.model,
			inputs = []string{request.input},
			options = request.options,
		},
		allocator,
	)
	if err != .None {
		return Embedding_Response{}, err
	}

	response := Embedding_Response {
		model           = batch.model,
		embedding       = batch.embeddings[0],
		inputTokenCount = batch.inputTokenCount,
		totalDuration   = batch.totalDuration,
		loadDuration    = batch.loadDuration,
	}
	batch.model = ""
	batch.embeddings[0] = {}
	delete(batch.embeddings)
	return response, .None
}

send_embeddings :: proc(
	client: Client,
	request: Embedding_Batch_Request,
	allocator := context.allocator,
) -> (
	Embedding_Batch_Response,
	AI_Error,
) {
	if request.model == "" ||
	   len(request.inputs) == 0 ||
	   (request.options.hasDimensions && request.options.dimensions <= 0) ||
	   (request.options.hasOllamaKeepAlive && request.options.ollamaKeepAlive == "") {
		return Embedding_Batch_Response{}, .Invalid_Request
	}
	for input in request.inputs {
		if input == "" {
			return Embedding_Batch_Response{}, .Invalid_Request
		}
	}
	if !model_supported(client.iface, request.model) {
		return Embedding_Batch_Response{}, .Unsupported_Model
	}

	if client.iface.type == .OpenAI {
		return send_openai_embeddings(client, request, allocator)
	}
	if client.iface.type == .Ollama {
		return send_ollama_embeddings(client, request, allocator)
	}

	return Embedding_Batch_Response{}, .Unsupported_Interface
}

send_chat_completion_stream :: proc(
	client: Client,
	request: Chat_Request,
	callback: Chat_Stream_Callback,
) -> AI_Error {
	return send_chat_completion_stream_internal(
		client,
		request,
		Chat_Stream_Callback_State{callback = callback},
	)
}

send_chat_completion_stream_with_context :: proc(
	client: Client,
	request: Chat_Request,
	callback: Chat_Stream_Context_Callback,
	userData: rawptr,
) -> AI_Error {
	return send_chat_completion_stream_internal(
		client,
		request,
		Chat_Stream_Callback_State{callbackWithContext = callback, userData = userData},
	)
}

send_chat_completion_stream_internal :: proc(
	client: Client,
	request: Chat_Request,
	callbackState: Chat_Stream_Callback_State,
) -> AI_Error {
	if request.model == "" ||
	   len(request.messages) == 0 ||
	   !chat_stream_callback_valid(callbackState) {
		return .Invalid_Request
	}
	if !model_supported(client.iface, request.model) {
		return .Unsupported_Model
	}

	if client.iface.type == .OpenAI {
		return send_openai_chat_completion_stream(client, request, callbackState)
	}
	if client.iface.type == .Anthropic {
		return send_anthropic_chat_completion_stream(client, request, callbackState)
	}
	if client.iface.type == .Ollama {
		return send_ollama_chat_completion_stream(client, request, callbackState)
	}

	return .Unsupported_Interface
}

Chat_Stream_Callback_State :: struct {
	callback:            Chat_Stream_Callback,
	callbackWithContext: Chat_Stream_Context_Callback,
	userData:            rawptr,
	parserData:          rawptr,
}

chat_stream_callback_valid :: proc(state: Chat_Stream_Callback_State) -> bool {
	return state.callback != nil || state.callbackWithContext != nil
}

chat_stream_callback_call :: proc(
	state: Chat_Stream_Callback_State,
	delta: Chat_Stream_Delta,
) -> bool {
	if state.callbackWithContext != nil {
		return state.callbackWithContext(delta, state.userData)
	}
	return state.callback(delta)
}

list_models :: proc(
	client: Client,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	if client.iface.type == .OpenAI {
		return list_openai_models(client, allocator)
	}
	if client.iface.type == .Anthropic {
		return list_anthropic_models(client, allocator)
	}
	if client.iface.type == .Ollama {
		models, err := list_ollama_models(client, allocator)
		if err != .None {
			return [dynamic]string{}, err
		}
		defer models_destroy(&models)

		names: [dynamic]string
		for model in models {
			append(&names, strings.clone(model.name, allocator))
		}
		return names, .None
	}

	return [dynamic]string{}, .Unsupported_Interface
}

send_openai_chat_completion :: proc(
	client: Client,
	request: Chat_Request,
) -> (
	Chat_Response,
	AI_Error,
) {
	target, ok := compose_endpoint_target(client.iface.endpoint, OPENAI_CHAT_PATH)
	if !ok {
		return Chat_Response{}, .Invalid_Request
	}

	wire := build_openai_chat_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Chat_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_openai_chat_response(body)
	}

	_ = parse_openai_error_message(body)
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
	target, ok := compose_endpoint_target(client.iface.endpoint, OPENAI_EMBEDDINGS_PATH)
	if !ok {
		return Embedding_Batch_Response{}, .Invalid_Request
	}

	wire := build_openai_embedding_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Embedding_Batch_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_openai_embedding_response(body, len(request.inputs), allocator)
	}

	_ = parse_openai_error_message(body)
	return Embedding_Batch_Response{}, map_status_to_error(status)
}

send_openai_chat_completion_stream :: proc(
	client: Client,
	request: Chat_Request,
	callbackState: Chat_Stream_Callback_State,
) -> AI_Error {
	target, ok := compose_endpoint_target(client.iface.endpoint, OPENAI_CHAT_PATH)
	if !ok {
		return .Invalid_Request
	}

	wire := build_openai_chat_stream_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	toolState: OpenAI_Stream_Tool_State
	defer openai_stream_tool_state_destroy(&toolState)
	streamCallbackState := callbackState
	streamCallbackState.parserData = rawptr(&toolState)

	body, status, errKind := do_json_post_stream(
		target,
		wire,
		extraHeaders[:],
		streamCallbackState,
		parse_openai_stream_event,
		parse_sse_stream_chunk,
	)
	if errKind != .None {
		return errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return .None
	}

	_ = parse_openai_error_message(body)
	return map_status_to_error(status)
}

send_anthropic_chat_completion :: proc(
	client: Client,
	request: Chat_Request,
) -> (
	Chat_Response,
	AI_Error,
) {
	if client.apiKey == "" {
		return Chat_Response{}, .Authentication_Error
	}

	target, ok := compose_endpoint_target(client.iface.endpoint, ANTHROPIC_MESSAGES_PATH)
	if !ok {
		return Chat_Response{}, .Invalid_Request
	}

	wire := build_anthropic_request(request)
	headers := [][2]string{{"x-api-key", client.apiKey}, {"anthropic-version", ANTHROPIC_VERSION}}

	body, status, errKind := do_json_post(target, wire, headers)
	if errKind != .None {
		return Chat_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_anthropic_response(body)
	}

	_ = parse_anthropic_error_message(body)
	return Chat_Response{}, map_status_to_error(status)
}

send_anthropic_chat_completion_stream :: proc(
	client: Client,
	request: Chat_Request,
	callbackState: Chat_Stream_Callback_State,
) -> AI_Error {
	if client.apiKey == "" {
		return .Authentication_Error
	}

	target, ok := compose_endpoint_target(client.iface.endpoint, ANTHROPIC_MESSAGES_PATH)
	if !ok {
		return .Invalid_Request
	}

	wire := build_anthropic_stream_request(request)
	headers := [][2]string{{"x-api-key", client.apiKey}, {"anthropic-version", ANTHROPIC_VERSION}}
	toolState: Anthropic_Stream_Tool_State
	defer anthropic_stream_tool_state_destroy(&toolState)
	streamCallbackState := callbackState
	streamCallbackState.parserData = rawptr(&toolState)

	body, status, errKind := do_json_post_stream(
		target,
		wire,
		headers,
		streamCallbackState,
		parse_anthropic_stream_event,
		parse_sse_stream_chunk,
	)
	if errKind != .None {
		return errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return .None
	}

	_ = parse_anthropic_error_message(body)
	return map_status_to_error(status)
}

list_openai_models :: proc(
	client: Client,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	target, ok := compose_endpoint_target(client.iface.endpoint, OPENAI_MODELS_PATH)
	if !ok {
		return [dynamic]string{}, .Invalid_Request
	}

	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_get(target, extraHeaders[:])
	if errKind != .None {
		return [dynamic]string{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_openai_models_response(body, allocator)
	}

	_ = parse_openai_error_message(body)
	return [dynamic]string{}, map_status_to_error(status)
}

list_anthropic_models :: proc(
	client: Client,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	if client.apiKey == "" {
		return [dynamic]string{}, .Authentication_Error
	}

	target, ok := compose_endpoint_target(client.iface.endpoint, ANTHROPIC_MODELS_PATH)
	if !ok {
		return [dynamic]string{}, .Invalid_Request
	}

	headers := [][2]string{{"x-api-key", client.apiKey}, {"anthropic-version", ANTHROPIC_VERSION}}

	body, status, errKind := do_json_get(target, headers)
	if errKind != .None {
		return [dynamic]string{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_anthropic_models_response(body, allocator)
	}

	_ = parse_anthropic_error_message(body)
	return [dynamic]string{}, map_status_to_error(status)
}

send_ollama_chat_completion :: proc(
	client: Client,
	request: Chat_Request,
) -> (
	Chat_Response,
	AI_Error,
) {
	target, ok := compose_endpoint_target(client.iface.endpoint, OLLAMA_CHAT_PATH)
	if !ok {
		return Chat_Response{}, .Invalid_Request
	}

	wire := build_ollama_chat_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Chat_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_ollama_chat_response(body)
	}

	_ = parse_ollama_error_message(body)
	return Chat_Response{}, map_status_to_error(status)
}

send_ollama_embeddings :: proc(
	client: Client,
	request: Embedding_Batch_Request,
	allocator := context.allocator,
) -> (
	Embedding_Batch_Response,
	AI_Error,
) {
	target, ok := compose_endpoint_target(client.iface.endpoint, OLLAMA_EMBED_PATH)
	if !ok {
		return Embedding_Batch_Response{}, .Invalid_Request
	}

	wire := build_ollama_embedding_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Embedding_Batch_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_ollama_embedding_response(body, len(request.inputs), allocator)
	}

	_ = parse_ollama_error_message(body)
	return Embedding_Batch_Response{}, map_status_to_error(status)
}

send_ollama_chat_completion_stream :: proc(
	client: Client,
	request: Chat_Request,
	callbackState: Chat_Stream_Callback_State,
) -> AI_Error {
	target, ok := compose_endpoint_target(client.iface.endpoint, OLLAMA_CHAT_PATH)
	if !ok {
		return .Invalid_Request
	}

	wire := build_ollama_chat_stream_request(request)
	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}
	toolState: Ollama_Stream_Tool_State
	streamCallbackState := callbackState
	streamCallbackState.parserData = rawptr(&toolState)

	body, status, errKind := do_json_post_stream(
		target,
		wire,
		extraHeaders[:],
		streamCallbackState,
		parse_ollama_stream_event,
		parse_json_lines_stream_chunk,
	)
	if errKind != .None {
		return errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return .None
	}

	_ = parse_ollama_error_message(body)
	return map_status_to_error(status)
}

list_ollama_models :: proc(
	client: Client,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	target, ok := compose_endpoint_target(client.iface.endpoint, OLLAMA_MODELS_PATH)
	if !ok {
		return [dynamic]Model{}, .Invalid_Request
	}

	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)

	if client.apiKey != "" {
		authorization := strings.concatenate({"Bearer ", client.apiKey}, context.temp_allocator)
		append(&extraHeaders, [2]string{"authorization", authorization})
	}

	body, status, errKind := do_json_get(target, extraHeaders[:])
	if errKind != .None {
		return [dynamic]Model{}, errKind
	}
	defer if body != "" {delete(body)}

	if http.status_is_success(status) {
		return parse_ollama_models_response(body, allocator)
	}

	_ = parse_ollama_error_message(body)
	return [dynamic]Model{}, map_status_to_error(status)
}

compose_endpoint_target :: proc(endpoint: http.URL, pathSuffix: string) -> (string, bool) {
	if endpoint.host == "" || endpoint.raw == "" {
		return "", false
	}

	hasRawSuffixSlash := strings.has_suffix(endpoint.raw, "/")
	hasPathPrefixSlash := strings.has_prefix(pathSuffix, "/")

	switch {
	case hasRawSuffixSlash && hasPathPrefixSlash:
		return strings.concatenate({endpoint.raw, pathSuffix[1:]}, context.temp_allocator), true
	case !hasRawSuffixSlash && !hasPathPrefixSlash:
		return strings.concatenate({endpoint.raw, "/", pathSuffix}, context.temp_allocator), true
	case:
		return strings.concatenate({endpoint.raw, pathSuffix}, context.temp_allocator), true
	}
}

do_json_post :: proc(
	target: string,
	payload: $T,
	extraHeaders: [][2]string,
) -> (
	body: string,
	status: http.Status,
	err: AI_Error,
) {
	req: httpClient.Request
	httpClient.request_init(&req, .Post)
	defer httpClient.request_destroy(&req)

	for header in extraHeaders {
		http.headers_set_unsafe(&req.headers, header[0], header[1])
	}

	jsonErr := httpClient.with_json(&req, payload)
	if jsonErr != nil {
		return "", http.Status(0), .Invalid_Request
	}

	_ = raw_http_log_begin(target)

	res, reqErr := httpClient.request(&req, target)
	if reqErr != nil {
		_ = raw_http_log_append("end: network error\n")
		return "", http.Status(0), .Network_Error
	}
	defer httpClient.response_destroy(&res)

	status = res.status
	_ = raw_http_log_append(fmt.tprintf("status: %d\nraw body:\n", int(status)))
	resBody, allocated, bodyErr := httpClient.response_body(&res)
	if bodyErr != nil {
		_ = raw_http_log_append("\nend: invalid response body\n")
		return "", status, .Invalid_Response
	}
	defer httpClient.body_destroy(resBody, allocated)

	#partial switch plain in resBody {
	case httpClient.Body_Plain:
		body = strings.clone(plain)
	}
	_ = raw_http_log_append(body)

	if body == "" && !http.status_is_success(status) {
		_ = raw_http_log_append("\nend: empty error response\n")
		return "", status, map_status_to_error(status)
	}

	_ = raw_http_log_append("\nend: complete\n")
	return body, status, .None
}

Stream_Chunk_Parser :: #type proc(
	_: ^Stream_Parse_State,
	_: string,
	_: Chat_Stream_Callback_State,
	_: Stream_Event_Parser,
) -> (
	bool,
	AI_Error,
)

do_json_post_stream :: proc(
	target: string,
	payload: $T,
	extraHeaders: [][2]string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> (
	body: string,
	status: http.Status,
	err: AI_Error,
) {
	req: httpClient.Request
	httpClient.request_init(&req, .Post)
	defer httpClient.request_destroy(&req)

	for header in extraHeaders {
		http.headers_set_unsafe(&req.headers, header[0], header[1])
	}

	jsonErr := httpClient.with_json(&req, payload)
	if jsonErr != nil {
		return "", http.Status(0), .Invalid_Request
	}

	_ = raw_http_log_begin(target)

	res, reqErr := httpClient.request(&req, target)
	if reqErr != nil {
		_ = raw_http_log_append("end: network error\n")
		return "", http.Status(0), .Network_Error
	}
	defer httpClient.response_destroy(&res)

	status = res.status
	if !http.status_is_success(status) {
		body, status, err = read_response_body(&res, status)
		_ = raw_http_log_append(fmt.tprintf("status: %d\nraw body:\n", int(status)))
		_ = raw_http_log_append(body)
		_ = raw_http_log_append(fmt.tprintf("\nend: %v\n", err))
		return body, status, err
	}
	_ = raw_http_log_append(fmt.tprintf("status: %d\n", int(status)))

	state: Stream_Parse_State
	defer destroy_stream_parse_state(&state)

	err = stream_response_body(&res, &state, callbackState, parse_event, parse_chunk)
	_ = raw_http_log_append(fmt.tprintf("\nend: %v\n", err))
	return "", status, err
}

read_response_body :: proc(
	res: ^httpClient.Response,
	status: http.Status,
) -> (
	string,
	http.Status,
	AI_Error,
) {
	body := ""
	resBody, allocated, bodyErr := httpClient.response_body(res)
	if bodyErr != nil {
		return "", status, .Invalid_Response
	}
	defer httpClient.body_destroy(resBody, allocated)

	#partial switch plain in resBody {
	case httpClient.Body_Plain:
		body = strings.clone(plain)
	}

	if body == "" && !http.status_is_success(status) {
		return "", status, map_status_to_error(status)
	}

	return body, status, .None
}

stream_response_body :: proc(
	res: ^httpClient.Response,
	state: ^Stream_Parse_State,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> AI_Error {
	enc, hasEnc := http.headers_get_unsafe(res.headers, "transfer-encoding")
	length, hasLength := http.headers_get_unsafe(res.headers, "content-length")

	switch {
	case hasEnc && strings.has_suffix(enc, "chunked"):
		_ = raw_http_log_append("transfer: chunked\nraw stream:\n")
		return stream_chunked_response_body(res, state, callbackState, parse_event, parse_chunk)
	case hasLength:
		_ = raw_http_log_append(fmt.tprintf("transfer: content-length %s\nraw stream:\n", length))
		return stream_length_response_body(
			res,
			length,
			state,
			callbackState,
			parse_event,
			parse_chunk,
		)
	case:
		_ = raw_http_log_append("transfer: line-scan\nraw stream:\n")
		return stream_line_response_body(res, state, callbackState, parse_event, parse_chunk)
	}
}

stream_chunked_response_body :: proc(
	res: ^httpClient.Response,
	state: ^Stream_Parse_State,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> AI_Error {
	defer reset_stream_scanner(res)

	for {
		if !bufio.scanner_scan(&res._body) {
			_ = raw_http_log_append("\nstream error: missing chunk size\n")
			return .Invalid_Response
		}

		sizeLine := bufio.scanner_bytes(&res._body)
		if semi := bytes.index_byte(sizeLine, ';'); semi > -1 {
			sizeLine = sizeLine[:semi]
		}

		size, ok := strconv.parse_int(string(sizeLine), 16)
		if !ok {
			_ = raw_http_log_append("\nstream error: invalid chunk size\n")
			return .Invalid_Response
		}
		if size == 0 {
			return consume_chunked_trailers(res)
		}

		context.user_index = size
		res._body.max_token_size = size
		res._body.split = stream_scan_num_bytes

		if !bufio.scanner_scan(&res._body) {
			_ = raw_http_log_append("\nstream error: missing chunk body\n")
			return .Invalid_Response
		}

		res._body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		res._body.split = bufio.scan_lines
		chunk := string(bufio.scanner_bytes(&res._body))
		_ = raw_http_log_append(chunk)

		stop, err := parse_chunk(state, chunk, callbackState, parse_event)
		if err != .None || stop {
			if stop {
				_ = raw_http_log_append("\nstream stopped by callback\n")
			} else {
				_ = raw_http_log_append(fmt.tprintf("\nstream error: %v\n", err))
			}
			return err
		}

		if !bufio.scanner_scan(&res._body) || bufio.scanner_text(&res._body) != "" {
			_ = raw_http_log_append("\nstream error: invalid chunk terminator\n")
			return .Invalid_Response
		}
	}
}

reset_stream_scanner :: proc(res: ^httpClient.Response) {
	res._body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	res._body.split = bufio.scan_lines
}

consume_chunked_trailers :: proc(res: ^httpClient.Response) -> AI_Error {
	for {
		if !bufio.scanner_scan(&res._body) {
			return .None
		}
		if bufio.scanner_text(&res._body) == "" {
			return .None
		}
	}
}

stream_length_response_body :: proc(
	res: ^httpClient.Response,
	length: string,
	state: ^Stream_Parse_State,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> AI_Error {
	remaining, ok := strconv.parse_int(length, 10)
	if !ok || remaining < 0 {
		return .Invalid_Response
	}
	defer reset_stream_scanner(res)

	for remaining > 0 {
		chunkSize := min(remaining, 4096)
		context.user_index = chunkSize
		res._body.max_token_size = chunkSize
		res._body.split = stream_scan_num_bytes

		if !bufio.scanner_scan(&res._body) {
			_ = raw_http_log_append("\nstream error: missing fixed-length chunk\n")
			return .Invalid_Response
		}
		chunk := string(bufio.scanner_bytes(&res._body))
		_ = raw_http_log_append(chunk)

		stop, err := parse_chunk(state, chunk, callbackState, parse_event)
		if err != .None || stop {
			if stop {
				_ = raw_http_log_append("\nstream stopped by callback\n")
			} else {
				_ = raw_http_log_append(fmt.tprintf("\nstream error: %v\n", err))
			}
			return err
		}

		remaining -= chunkSize
	}

	return .None
}

stream_line_response_body :: proc(
	res: ^httpClient.Response,
	state: ^Stream_Parse_State,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> AI_Error {
	for bufio.scanner_scan(&res._body) {
		line := strings.concatenate({bufio.scanner_text(&res._body), "\n"})
		_ = raw_http_log_append(line)
		stop, err := parse_chunk(state, line, callbackState, parse_event)
		delete(line)
		if err != .None || stop {
			if stop {
				_ = raw_http_log_append("\nstream stopped by callback\n")
			} else {
				_ = raw_http_log_append(fmt.tprintf("\nstream error: %v\n", err))
			}
			return err
		}
	}

	return .None
}

stream_scan_num_bytes :: proc(
	data: []byte,
	atEOF: bool,
) -> (
	advance: int,
	token: []byte,
	err: bufio.Scanner_Error,
	finalToken: bool,
) {
	n := context.user_index
	if atEOF && len(data) < n {
		return
	}
	if len(data) < n {
		return
	}

	return n, data[:n], nil, false
}

do_json_get :: proc(
	target: string,
	extraHeaders: [][2]string,
) -> (
	body: string,
	status: http.Status,
	err: AI_Error,
) {
	req: httpClient.Request
	httpClient.request_init(&req, .Get)
	defer httpClient.request_destroy(&req)

	for header in extraHeaders {
		http.headers_set_unsafe(&req.headers, header[0], header[1])
	}

	res, reqErr := httpClient.request(&req, target)
	if reqErr != nil {
		return "", http.Status(0), .Network_Error
	}
	defer httpClient.response_destroy(&res)

	status = res.status
	resBody, allocated, bodyErr := httpClient.response_body(&res)
	if bodyErr != nil {
		return "", status, .Invalid_Response
	}
	defer httpClient.body_destroy(resBody, allocated)

	#partial switch plain in resBody {
	case httpClient.Body_Plain:
		body = strings.clone(plain)
	}

	if body == "" && !http.status_is_success(status) {
		return "", status, map_status_to_error(status)
	}

	return body, status, .None
}

Stream_Event_Parser :: #type proc(_: string, _: Chat_Stream_Callback_State) -> (bool, AI_Error)

Stream_Parse_State :: struct {
	pending: string,
}

destroy_stream_parse_state :: proc(state: ^Stream_Parse_State) {
	if state.pending != "" {
		delete(state.pending)
	}
	state.pending = ""
}

append_stream_pending :: proc(state: ^Stream_Parse_State, chunk: string) -> string {
	if state.pending == "" {
		return strings.clone(chunk)
	}

	combined := strings.concatenate({state.pending, chunk})
	delete(state.pending)
	state.pending = ""
	return combined
}

first_sse_event_boundary :: proc(body: string) -> (idx: int, size: int, ok: bool) {
	lfIdx := strings.index(body, "\n\n")
	crlfIdx := strings.index(body, "\r\n\r\n")

	if lfIdx == -1 && crlfIdx == -1 {
		return 0, 0, false
	}
	if lfIdx == -1 {
		return crlfIdx, len("\r\n\r\n"), true
	}
	if crlfIdx == -1 || lfIdx < crlfIdx {
		return lfIdx, len("\n\n"), true
	}

	return crlfIdx, len("\r\n\r\n"), true
}

parse_sse_stream_chunk :: proc(
	state: ^Stream_Parse_State,
	chunk: string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
) -> (
	stop: bool,
	err: AI_Error,
) {
	if chunk == "" {
		return false, .None
	}

	body := append_stream_pending(state, chunk)
	defer delete(body)
	remaining := body

	for {
		boundary, boundarySize, hasBoundary := first_sse_event_boundary(remaining)
		if !hasBoundary {
			if remaining != "" {
				state.pending = strings.clone(remaining)
			}
			return false, .None
		}

		eventBlock := remaining[:boundary]
		eventData := ""
		lines := strings.split_lines(eventBlock, context.temp_allocator)
		defer delete(lines, context.temp_allocator)

		for line in lines {
			trimmedLine := strings.trim_space(line)
			if strings.has_prefix(trimmedLine, "data:") {
				eventData = strings.trim_space(trimmedLine[len("data:"):])
			}
		}

		stop, err = parse_event(eventData, callbackState)
		if err != .None || stop {
			return stop, err
		}

		remaining = remaining[boundary + boundarySize:]
	}
}

parse_json_lines_stream_chunk :: proc(
	state: ^Stream_Parse_State,
	chunk: string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
) -> (
	stop: bool,
	err: AI_Error,
) {
	if chunk == "" {
		return false, .None
	}

	body := append_stream_pending(state, chunk)
	defer delete(body)
	remaining := body

	for {
		lineEnd := strings.index_byte(remaining, '\n')
		if lineEnd == -1 {
			if remaining != "" {
				state.pending = strings.clone(remaining)
			}
			return false, .None
		}

		line := strings.trim_space(remaining[:lineEnd])
		if line != "" {
			stop, err = parse_event(line, callbackState)
			if err != .None || stop {
				return stop, err
			}
		}

		remaining = remaining[lineEnd + 1:]
	}
}

parse_sse_stream_body :: proc(
	body: string,
	callback: Chat_Stream_Callback,
	parse_event: Stream_Event_Parser,
) -> AI_Error {
	return parse_sse_stream_body_internal(
		body,
		Chat_Stream_Callback_State{callback = callback},
		parse_event,
	)
}

parse_sse_stream_body_internal :: proc(
	body: string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
) -> AI_Error {
	events := strings.split(body, "\n\n", context.temp_allocator)
	defer delete(events, context.temp_allocator)

	for eventBlock in events {
		eventData := ""
		lines := strings.split_lines(eventBlock, context.temp_allocator)
		defer delete(lines, context.temp_allocator)

		for line in lines {
			trimmedLine := strings.trim_space(line)
			if strings.has_prefix(trimmedLine, "data:") {
				eventData = strings.trim_space(trimmedLine[len("data:"):])
			}
		}

		stop, err := parse_event(eventData, callbackState)
		if err != .None {
			return err
		}
		if stop {
			return .None
		}
	}

	return .None
}

parse_json_lines_stream_body :: proc(
	body: string,
	callback: Chat_Stream_Callback,
	parse_event: Stream_Event_Parser,
) -> AI_Error {
	return parse_json_lines_stream_body_internal(
		body,
		Chat_Stream_Callback_State{callback = callback},
		parse_event,
	)
}

parse_json_lines_stream_body_internal :: proc(
	body: string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
) -> AI_Error {
	lines := strings.split_lines(body, context.temp_allocator)
	defer delete(lines, context.temp_allocator)

	for line in lines {
		trimmedLine := strings.trim_space(line)
		if trimmedLine == "" {
			continue
		}

		stop, err := parse_event(trimmedLine, callbackState)
		if err != .None {
			return err
		}
		if stop {
			return .None
		}
	}

	return .None
}

map_status_to_error :: proc(status: http.Status) -> AI_Error {
	#partial switch status {
	case .Unauthorized, .Forbidden:
		return .Authentication_Error
	case .Too_Many_Requests:
		return .Rate_Limited
	case:
		if http.status_is_server_error(status) {
			return .Server_Error
		}
		if http.status_is_client_error(status) {
			return .Provider_Error
		}
		return .Invalid_Response
	}
}
