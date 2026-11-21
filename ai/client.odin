package ai

import json "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

import transport "../transport"

MIMIR_USER_AGENT :: "Mimir/alpha"

OLLAMA_CHAT_PATH :: "/api/chat"
OLLAMA_EMBED_PATH :: "/api/embed"
OLLAMA_MODELS_PATH :: "/api/tags"
OLLAMA_SHOW_PATH :: "/api/show"

OPENAI_CHAT_PATH :: "/chat/completions"
OPENAI_EMBED_PATH :: "/embeddings"
OPENAI_MODELS_PATH :: "/models"

AI_Request_Purpose :: enum {
	Chat,
	Chat_Stream,
	Embedding,
	Models,
	Model_Metadata,
}

requestIDMutex: sync.Mutex
requestIDCounter: u64

send_chat_completion :: proc(client: Client, request: Chat_Request) -> (Chat_Response, AI_Error) {
	if request.model == "" || len(request.messages) == 0 {
		return Chat_Response{}, .Invalid_Request
	}
	if !model_supported(client.iface, request.model) {
		return Chat_Response{}, .Unsupported_Model
	}

	if client.iface.type == .Ollama {
		return send_ollama_chat_completion(client, request)
	}
	if client.iface.type == .OpenAI {
		return send_openai_chat_completion(client, request)
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

	if client.iface.type == .Ollama {
		return send_ollama_embeddings(client, request, allocator)
	}
	if client.iface.type == .OpenAI {
		return send_openai_embeddings(client, request, allocator)
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

// Like send_chat_completion_stream_with_context, but `shouldCancel` is polled while the
// request is in flight so a cancellation aborts the transfer without waiting for data.
send_chat_completion_stream_with_cancel :: proc(
	client: Client,
	request: Chat_Request,
	callback: Chat_Stream_Context_Callback,
	shouldCancel: Chat_Stream_Cancel_Callback,
	userData: rawptr,
) -> AI_Error {
	return send_chat_completion_stream_internal(
		client,
		request,
		Chat_Stream_Callback_State {
			callbackWithContext = callback,
			shouldCancel = shouldCancel,
			userData = userData,
		},
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

	if client.iface.type == .Ollama {
		return send_ollama_chat_completion_stream(client, request, callbackState)
	}
	if client.iface.type == .OpenAI {
		return send_openai_chat_completion_stream(client, request, callbackState)
	}

	return .Unsupported_Interface
}

Chat_Stream_Callback_State :: struct {
	callback:            Chat_Stream_Callback,
	callbackWithContext: Chat_Stream_Context_Callback,
	// Optional. Polled while the request is in flight; returning true aborts it.
	shouldCancel:        Chat_Stream_Cancel_Callback,
	userData:            rawptr,
	parserData:          rawptr,
}

chat_stream_cancel_requested :: proc(state: Chat_Stream_Callback_State) -> bool {
	return state.shouldCancel != nil && state.shouldCancel(state.userData)
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
	if client.iface.type == .OpenAI {
		models, err := list_openai_models(client, allocator)
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

	append_standard_ai_headers(&extraHeaders, client.iface.type, .Chat)
	append_api_key_auth_headers(&extraHeaders, client.apiKey)

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Chat_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if transport.status_is_success(status) {
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

	append_standard_ai_headers(&extraHeaders, client.iface.type, .Embedding)
	append_api_key_auth_headers(&extraHeaders, client.apiKey)

	body, status, errKind := do_json_post(target, wire, extraHeaders[:])
	if errKind != .None {
		return Embedding_Batch_Response{}, errKind
	}
	defer if body != "" {delete(body)}

	if transport.status_is_success(status) {
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

	append_standard_ai_headers(&extraHeaders, client.iface.type, .Chat_Stream)
	append_api_key_auth_headers(&extraHeaders, client.apiKey)
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

	if transport.status_is_success(status) {
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

	append_standard_ai_headers(&extraHeaders, client.iface.type, .Models)
	append_api_key_auth_headers(&extraHeaders, client.apiKey)

	body, status, errKind := do_json_get(target, extraHeaders[:])
	if errKind != .None {
		return [dynamic]Model{}, errKind
	}
	defer if body != "" {delete(body)}

	if transport.status_is_success(status) {
		return parse_ollama_models_response(body, allocator)
	}

	_ = parse_ollama_error_message(body)
	return [dynamic]Model{}, map_status_to_error(status)
}

compose_endpoint_target :: proc(endpoint: transport.URL, pathSuffix: string) -> (string, bool) {
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

append_api_key_auth_headers :: proc(extraHeaders: ^[dynamic][2]string, apiKey: string) {
	if apiKey == "" {
		return
	}

	authorization := strings.concatenate({"Bearer ", apiKey}, context.temp_allocator)
	append(extraHeaders, [2]string{"authorization", authorization})
	append(extraHeaders, [2]string{"x-api-key", apiKey})
}

append_standard_ai_headers :: proc(
	extraHeaders: ^[dynamic][2]string,
	providerType: Interface_Type,
	purpose: AI_Request_Purpose,
) {
	append(extraHeaders, [2]string{"user-agent", MIMIR_USER_AGENT})
	append(extraHeaders, [2]string{"accept", ai_request_accept_header(purpose)})
	append(extraHeaders, [2]string{"x-request-id", next_ai_request_id()})
	append(extraHeaders, [2]string{"x-initiator", "user"})
	append(extraHeaders, [2]string{"x-interaction-type", ai_request_interaction_type(purpose)})

	if providerType == .OpenAI && (purpose == .Chat || purpose == .Chat_Stream) {
		append(extraHeaders, [2]string{"openai-intent", "conversation-other"})
	}
}

ai_request_accept_header :: proc(purpose: AI_Request_Purpose) -> string {
	switch purpose {
	case .Chat_Stream:
		return "text/event-stream, application/json"
	case .Chat, .Embedding, .Models, .Model_Metadata:
		return "application/json"
	}
	return "application/json"
}

ai_request_interaction_type :: proc(purpose: AI_Request_Purpose) -> string {
	switch purpose {
	case .Chat:
		return "conversation"
	case .Chat_Stream:
		return "conversation-stream"
	case .Embedding:
		return "embedding"
	case .Models:
		return "model-list"
	case .Model_Metadata:
		return "model-metadata"
	}
	return "conversation"
}

next_ai_request_id :: proc() -> string {
	sync.mutex_lock(&requestIDMutex)
	requestIDCounter += 1
	id := requestIDCounter
	sync.mutex_unlock(&requestIDMutex)

	return fmt.tprintf("mimir-%d", id)
}

// Set the connect and stall timeouts, in seconds, for later requests.
// A value of 0 or less selects the transport default.
set_request_timeouts :: proc(connectSeconds: int, stallSeconds: int) {
	transport.set_timeouts(connectSeconds, stallSeconds)
}

// Build the header list for a JSON request body.
json_request_headers :: proc(extraHeaders: [][2]string) -> [][2]string {
	headers := make([dynamic][2]string, 0, len(extraHeaders) + 1, context.temp_allocator)
	append(&headers, [2]string{"content-type", "application/json"})
	for header in extraHeaders {
		if header[0] == "content-type" {
			continue
		}
		append(&headers, header)
	}
	return headers[:]
}

transport_error_to_ai_error :: proc(err: transport.Error) -> AI_Error {
	switch err {
	case .None, .Canceled:
		return .None
	case .Invalid_Request:
		return .Invalid_Request
	case .Network_Error, .Timeout:
		return .Network_Error
	case .Invalid_Response:
		return .Invalid_Response
	}
	return .Network_Error
}

// Send a JSON request and log the exchange. Shared by do_json_post and do_json_get.
do_buffered_request :: proc(
	req: transport.Request,
) -> (
	body: string,
	status: transport.Status,
	err: AI_Error,
) {
	_ = raw_http_log_begin(req.target)

	transportErr: transport.Error
	status, body, transportErr = transport.request(req)
	if transportErr != .None {
		_ = raw_http_log_append(fmt.tprintf("end: %v\n", transportErr))
		return body, status, transport_error_to_ai_error(transportErr)
	}

	_ = raw_http_log_append(fmt.tprintf("status: %d\nraw body:\n", int(status)))
	_ = raw_http_log_append(body)

	if body == "" && !transport.status_is_success(status) {
		_ = raw_http_log_append("\nend: empty error response\n")
		return "", status, map_status_to_error(status)
	}

	_ = raw_http_log_append("\nend: complete\n")
	return body, status, .None
}

do_json_post :: proc(
	target: string,
	payload: $T,
	extraHeaders: [][2]string,
) -> (
	body: string,
	status: transport.Status,
	err: AI_Error,
) {
	payloadBytes, jsonErr := json.marshal(payload)
	if jsonErr != nil {
		return "", .Unknown, .Invalid_Request
	}
	defer delete(payloadBytes)

	return do_buffered_request(
		transport.Request {
			method = .Post,
			target = target,
			headers = json_request_headers(extraHeaders),
			body = payloadBytes,
		},
	)
}

do_json_get :: proc(
	target: string,
	extraHeaders: [][2]string,
) -> (
	body: string,
	status: transport.Status,
	err: AI_Error,
) {
	return do_buffered_request(
		transport.Request{method = .Get, target = target, headers = extraHeaders},
	)
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

// State shared with the transport stream handlers for one streaming request.
Stream_Request_State :: struct {
	parseState:    Stream_Parse_State,
	callbackState: Chat_Stream_Callback_State,
	parse_event:   Stream_Event_Parser,
	parse_chunk:   Stream_Chunk_Parser,
	started:       bool,
	stopped:       bool,
	err:           AI_Error,
}

stream_request_on_data :: proc(chunk: string, user: rawptr) -> bool {
	state := cast(^Stream_Request_State)user
	if !state.started {
		state.started = true
		_ = raw_http_log_append("raw stream:\n")
	}
	_ = raw_http_log_append(chunk)

	stop, err := state.parse_chunk(
		&state.parseState,
		chunk,
		state.callbackState,
		state.parse_event,
	)
	if err != .None {
		state.err = err
		return false
	}
	if stop {
		state.stopped = true
		return false
	}
	return true
}

stream_request_should_cancel :: proc(user: rawptr) -> bool {
	state := cast(^Stream_Request_State)user
	return chat_stream_cancel_requested(state.callbackState)
}

do_json_post_stream :: proc(
	target: string,
	payload: $T,
	extraHeaders: [][2]string,
	callbackState: Chat_Stream_Callback_State,
	parse_event: Stream_Event_Parser,
	parse_chunk: Stream_Chunk_Parser,
) -> (
	body: string,
	status: transport.Status,
	err: AI_Error,
) {
	payloadBytes, jsonErr := json.marshal(payload)
	if jsonErr != nil {
		return "", .Unknown, .Invalid_Request
	}
	defer delete(payloadBytes)

	_ = raw_http_log_begin(target)

	state := Stream_Request_State {
		callbackState = callbackState,
		parse_event   = parse_event,
		parse_chunk   = parse_chunk,
	}
	defer destroy_stream_parse_state(&state.parseState)

	transportErr: transport.Error
	status, body, transportErr = transport.request_stream(
		transport.Request {
			method = .Post,
			target = target,
			headers = json_request_headers(extraHeaders),
			body = payloadBytes,
		},
		transport.Stream_Handlers {
			on_data = stream_request_on_data,
			should_cancel = stream_request_should_cancel,
			user = &state,
		},
	)

	if state.started {
		_ = raw_http_log_append("\n")
	}
	_ = raw_http_log_append(fmt.tprintf("status: %d\n", int(status)))

	switch {
	case transportErr == .Canceled && state.err != .None:
		_ = raw_http_log_append(fmt.tprintf("stream error: %v\n", state.err))
		return "", status, state.err
	case transportErr == .Canceled:
		_ = raw_http_log_append("end: stream stopped by callback\n")
		return "", status, .None
	case transportErr != .None:
		_ = raw_http_log_append(fmt.tprintf("end: %v\n", transportErr))
		return body, status, transport_error_to_ai_error(transportErr)
	}

	if !transport.status_is_success(status) {
		_ = raw_http_log_append("raw body:\n")
		_ = raw_http_log_append(body)
		err = .None
		if body == "" {
			err = map_status_to_error(status)
		}
		_ = raw_http_log_append(fmt.tprintf("\nend: %v\n", err))
		return body, status, err
	}

	_ = raw_http_log_append("end: None\n")
	return "", status, .None
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

map_status_to_error :: proc(status: transport.Status) -> AI_Error {
	#partial switch status {
	case .Unauthorized, .Forbidden:
		return .Authentication_Error
	case .Too_Many_Requests:
		return .Rate_Limited
	case:
		if transport.status_is_server_error(status) {
			return .Server_Error
		}
		if transport.status_is_client_error(status) {
			return .Provider_Error
		}
		return .Invalid_Response
	}
}
