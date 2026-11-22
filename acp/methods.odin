package acp

import "../session"
import "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

// The ACP methods that Mimir implements: initialize, session/new, session/prompt,
// session/cancel, $/cancel_request and session/close.

// Returns the params of a request as an object. A missing params field is an empty object.
request_params :: proc(params: json.Value) -> (json.Object, bool) {
	if params == nil {
		return make(json.Object, 0, context.temp_allocator), true
	}
	object, isObject := params.(json.Object)
	return object, isObject
}

handle_initialize :: proc(conn: ^Connection, id: json.Value, params: json.Value) {
	if conn.initialized {
		connection_send_error(
			conn,
			id,
			ERROR_INVALID_REQUEST,
			"The connection is already initialized",
		)
		return
	}
	object, objectOK := request_params(params)
	if !objectOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "params must be an object")
		return
	}
	if _, versionOK := json_get_integer(object, "protocolVersion"); !versionOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "protocolVersion must be an integer")
		return
	}
	if capabilities, capabilitiesOK := json_get_object(object, "clientCapabilities");
	   capabilitiesOK {
		if sessionCapabilities, sessionOK := json_get_object(capabilities, "session"); sessionOK {
			conn.clientNotices = json_has_value(sessionCapabilities, "notices")
		}
		conn.clientSubagents = json_has_value(capabilities, "subagents")
	}
	if clientInfo, infoOK := json_get_object(object, "clientInfo"); infoOK {
		name, _ := json_get_string(clientInfo, "name")
		version, _ := json_get_string(clientInfo, "version")
		connection_log(conn, .Info, "client %s %s", name, version)
	}
	conn.initialized = true
	// Mimir answers with the only version it supports, whatever the client asked for.
	connection_send_result(
		conn,
		id,
		json_object(
			{"protocolVersion", json_integer(ACP_PROTOCOL_VERSION)},
			{
				"agentCapabilities",
				json_object(
					{"loadSession", false},
					{
						"promptCapabilities",
						json_object({"image", false}, {"audio", false}, {"embeddedContext", false}),
					},
					{"mcpCapabilities", json_object({"http", false}, {"sse", false})},
					{"sessionCapabilities", json_object({"close", json_object()})},
				),
			},
			{
				"agentInfo",
				json_object(
					{"name", "mimir"},
					{"title", "Mimir"},
					{"version", json.String(MIMIR_VERSION)},
				),
			},
			{"authMethods", json_array()},
		),
	)
}

handle_session_new :: proc(conn: ^Connection, id: json.Value, params: json.Value) {
	object, objectOK := request_params(params)
	if !objectOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "params must be an object")
		return
	}
	cwd, cwdOK := json_get_string(object, "cwd")
	if !cwdOK || !tool_policy.permission_path_is_absolute(cwd) {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "cwd must be an absolute path")
		return
	}
	projectRoot, rootOK := tool_policy.permission_normalize_absolute_path(
		cwd,
		context.temp_allocator,
	)
	if !rootOK || !os.is_dir(projectRoot) {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "cwd must be an existing directory")
		return
	}
	mcpServers, mcpOK := json_get_array(object, "mcpServers")
	if !mcpOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "mcpServers must be an array")
		return
	}
	if directories, hasDirectories := object["additionalDirectories"]; hasDirectories {
		array, isArray := directories.(json.Array)
		_, isNull := directories.(json.Null)
		if (isArray && len(array) > 0) || (!isArray && !isNull) {
			connection_send_error(
				conn,
				id,
				ERROR_INVALID_PARAMS,
				"additionalDirectories is not supported",
			)
			return
		}
	}
	if systemPrompt, hasSystemPrompt := object["systemPrompt"]; hasSystemPrompt {
		if _, isNull := systemPrompt.(json.Null); !isNull {
			connection_send_error(conn, id, ERROR_INVALID_PARAMS, "systemPrompt is not supported")
			return
		}
	}

	options := session.session_options_from_config(conn.config, projectRoot, conn.configHome)
	options.requireUsableModel = true
	created, createErr := session.session_create(conn.config, options, conn.allocator)
	#partial switch createErr {
	case .None:
	case .No_Usable_Model:
		connection_send_error(
			conn,
			id,
			ERROR_NO_USABLE_MODEL,
			"No usable provider or model is configured. Run mimir in a terminal to set one up.",
		)
		return
	case:
		connection_send_error(
			conn,
			id,
			ERROR_INTERNAL,
			fmt.tprintf("The session could not be created: %v", createErr),
		)
		return
	}

	conn.nextSessionNumber += 1
	entry := new(ACP_Session, conn.allocator)
	entry.id = fmt.aprintf("sess_%d", conn.nextSessionNumber, allocator = conn.allocator)
	entry.session = created
	entry.projectRoot = strings.clone(projectRoot, conn.allocator)
	entry.toolCalls = make([dynamic]^Tool_Call_View, 0, 8, conn.allocator)
	conn.sessions[entry.id] = entry
	connection_log(conn, .Info, "session %s in %s", entry.id, projectRoot)
	connection_send_result(conn, id, json_object({"sessionId", json.String(entry.id)}))

	if len(mcpServers) > 0 {
		names := make([dynamic]string, 0, len(mcpServers), context.temp_allocator)
		for server in mcpServers {
			name := "(unnamed)"
			if serverObject, isObject := server.(json.Object); isObject {
				if serverName, nameOK := json_get_string(serverObject, "name"); nameOK {
					name = serverName
				}
			}
			append(&names, name)
		}
		text := fmt.tprintf(
			"MCP servers are not supported and were ignored: %s",
			strings.join(names[:], ", ", context.temp_allocator),
		)
		connection_log(conn, .Warning, "%s: %s", entry.id, text)
		if conn.clientNotices {
			send_notice(conn, entry, .Warning, text)
		}
	}
}

// Returns the session of the sessionId field, or sends an error and returns nil.
request_session :: proc(
	conn: ^Connection,
	id: json.Value,
	object: json.Object,
) -> ^ACP_Session {
	sessionID, sessionOK := json_get_string(object, "sessionId")
	if !sessionOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "sessionId must be a string")
		return nil
	}
	entry, found := conn.sessions[sessionID]
	if !found || entry.closeRequested {
		connection_send_error(
			conn,
			id,
			ERROR_RESOURCE_NOT_FOUND,
			"Session not found",
			json_object({"sessionId", json.String(sessionID)}),
		)
		return nil
	}
	return entry
}

handle_session_prompt :: proc(conn: ^Connection, id: json.Value, params: json.Value) {
	object, objectOK := request_params(params)
	if !objectOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "params must be an object")
		return
	}
	entry := request_session(conn, id, object)
	if entry == nil {
		return
	}
	prompt, promptOK := json_get_array(object, "prompt")
	if !promptOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "prompt must be an array")
		return
	}
	text, textOK, textError := prompt_text(entry.projectRoot, prompt)
	if !textOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, textError)
		return
	}
	sessionData := json_object({"sessionId", json.String(entry.id)})
	if entry.promptOpen {
		connection_send_error(
			conn,
			id,
			ERROR_SESSION_BUSY,
			"Session has an active turn",
			sessionData,
		)
		return
	}
	submitErr := session.session_submit(entry.session, text)
	#partial switch submitErr {
	case .None:
	case .Busy:
		connection_send_error(
			conn,
			id,
			ERROR_SESSION_BUSY,
			"Session has an active turn",
			sessionData,
		)
		return
	case:
		message := last_notice_text(entry.session)
		if message == "" {
			message = "The turn could not start"
		}
		connection_send_error(conn, id, ERROR_INTERNAL, message, sessionData)
		return
	}
	acp_session_clear_turn(conn, entry)
	json_request_id_destroy(&entry.promptID, conn.allocator)
	entry.promptID = json_request_id_clone(id, conn.allocator)
	entry.promptOpen = true
	entry.cancelRequested = false
}

// Returns the text of the newest Notice event that the session has not given out yet.
last_notice_text :: proc(s: ^session.Session) -> string {
	for index := len(s.events) - 1; index >= 0; index -= 1 {
		if notice, isNotice := s.events[index].(session.Notice); isNotice {
			return notice.text
		}
	}
	return ""
}

// Cancels the turn of entry, for session/cancel and for $/cancel_request of the prompt.
cancel_prompt :: proc(conn: ^Connection, entry: ^ACP_Session) {
	if !entry.promptOpen {
		connection_log(conn, .Debug, "%s: cancel without an active prompt", entry.id)
		return
	}
	entry.cancelRequested = true
	if cancelErr := session.session_cancel_turn(entry.session); cancelErr != .None {
		connection_log(conn, .Debug, "%s: cancel: %v", entry.id, cancelErr)
	}
}

handle_session_cancel :: proc(conn: ^Connection, params: json.Value) {
	object, objectOK := request_params(params)
	sessionID, sessionOK := json_get_string(object, "sessionId")
	if !objectOK || !sessionOK {
		connection_log(conn, .Warning, "session/cancel without a sessionId")
		return
	}
	entry, found := conn.sessions[sessionID]
	if !found {
		connection_log(conn, .Warning, "session/cancel for unknown session %s", sessionID)
		return
	}
	cancel_prompt(conn, entry)
}

handle_cancel_request :: proc(conn: ^Connection, params: json.Value) {
	object, objectOK := request_params(params)
	requestID, requestOK := object["requestId"]
	if !objectOK || !requestOK {
		connection_log(conn, .Warning, "$/cancel_request without a requestId")
		return
	}
	for _, entry in conn.sessions {
		if entry.promptOpen && json_request_id_equal(entry.promptID, requestID) {
			cancel_prompt(conn, entry)
			return
		}
	}
	// Every other response is sent at once, so there is nothing to cancel.
	connection_log(conn, .Debug, "$/cancel_request for a request that is not open")
}

handle_session_close :: proc(conn: ^Connection, id: json.Value, params: json.Value) {
	object, objectOK := request_params(params)
	sessionID, sessionOK := json_get_string(object, "sessionId")
	if !objectOK || !sessionOK {
		connection_send_error(conn, id, ERROR_INVALID_PARAMS, "sessionId must be a string")
		return
	}
	entry, found := conn.sessions[sessionID]
	if !found || entry.closeRequested {
		// Closing is idempotent.
		connection_send_result(conn, id, json_object())
		return
	}
	entry.closeRequested = true
	entry.closeRequestID = json_request_id_clone(id, conn.allocator)
	entry.closeStarted = time.tick_now()
	if entry.promptOpen {
		cancel_prompt(conn, entry)
		// connection_tick finishes the close when the turn has ended.
		return
	}
	finish_session_close(conn, entry)
}

// Destroys a closing session and answers session/close. A prompt that is still open is
// answered with cancelled first.
finish_session_close :: proc(conn: ^Connection, entry: ^ACP_Session) {
	if entry.promptOpen {
		end_prompt(conn, entry, json_object({"stopReason", "cancelled"}), true)
	}
	// acp_session_destroy frees the stored ID.
	closeID := json_request_id_clone(entry.closeRequestID, context.temp_allocator)
	// Responses to the permission requests of this session are not needed any more.
	stale := make([dynamic]i64, 0, 2, context.temp_allocator)
	for requestID, request in conn.outbound {
		if request.sessionID == entry.id {
			append(&stale, requestID)
		}
	}
	for requestID in stale {
		_, request := delete_key(&conn.outbound, requestID)
		outbound_request_destroy(&request, conn.allocator)
	}
	connection_log(conn, .Info, "closed session %s", entry.id)
	delete_key(&conn.sessions, entry.id)
	acp_session_destroy(conn, entry)
	connection_send_result(conn, closeID, json_object())
}

// Answers the open session/prompt with result, or with an error when result is an error
// object built by the caller (isResult false sends errorValue). Every tool call of the turn
// without a final status is marked failed first, and buffered subagent text is sent.
end_prompt :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	result: json.Value,
	isResult: bool,
	errorCode := 0,
	errorMessage := "",
) {
	flush_subagent_text(conn, entry)
	for view in entry.toolCalls {
		if !view.final {
			view.final = true
			view.status = .Failed
			send_tool_call_update(conn, entry, view)
		}
	}
	acp_session_clear_turn(conn, entry)
	if entry.approval.active {
		approval_hold_clear(&entry.approval, conn.allocator)
	}
	if entry.promptOpen {
		if isResult {
			connection_send_result(conn, entry.promptID, result)
		} else {
			connection_send_error(
				conn,
				entry.promptID,
				errorCode,
				errorMessage,
				json_object({"sessionId", json.String(entry.id)}),
			)
		}
	}
	json_request_id_destroy(&entry.promptID, conn.allocator)
	entry.promptOpen = false
	entry.cancelRequested = false
}

// Builds the text that the session receives from ACP prompt content blocks. Only text and
// resource_link blocks are supported; Mimir does not advertise the other types.
prompt_text :: proc(
	projectRoot: string,
	prompt: json.Array,
) -> (
	text: string,
	ok: bool,
	errorText: string,
) {
	builder := strings.builder_make(context.temp_allocator)
	for block in prompt {
		object, isObject := block.(json.Object)
		if !isObject {
			return "", false, "Prompt content blocks must be objects"
		}
		blockType, _ := json_get_string(object, "type")
		switch blockType {
		case "text":
			blockText, textOK := json_get_string(object, "text")
			if !textOK {
				return "", false, "A text block needs text"
			}
			strings.write_string(&builder, blockText)
		case "resource_link":
			uri, uriOK := json_get_string(object, "uri")
			if !uriOK || uri == "" {
				return "", false, "A resource_link block needs a uri"
			}
			name, _ := json_get_string(object, "name")
			reference := resource_link_reference(projectRoot, uri)
			current := strings.to_string(builder)
			if len(current) > 0 && current[len(current) - 1] != '\n' {
				strings.write_byte(&builder, '\n')
			}
			strings.write_byte(&builder, '@')
			strings.write_string(&builder, reference)
			if name != "" && name != last_path_segment(reference) {
				strings.write_string(&builder, " (")
				strings.write_string(&builder, name)
				strings.write_byte(&builder, ')')
			}
			strings.write_byte(&builder, '\n')
		case:
			return "", false, fmt.tprintf("Unsupported prompt content type %q", blockType)
		}
	}
	result := strings.trim_right(strings.to_string(builder), "\n")
	if strings.trim_space(result) == "" {
		return "", false, "The prompt is empty"
	}
	return result, true, ""
}

// Returns how a resource_link appears in the prompt: the path relative to the project root for
// a file:// URI inside the root, or else the URI.
resource_link_reference :: proc(projectRoot, uri: string) -> string {
	if !strings.has_prefix(uri, "file://") {
		return uri
	}
	rest := uri[len("file://"):]
	if strings.has_prefix(rest, "localhost/") {
		rest = rest[len("localhost"):]
	}
	decoded, decodedOK := net.percent_decode(rest, context.temp_allocator)
	if !decodedOK {
		return uri
	}
	path := decoded
	when ODIN_OS == .Windows {
		// file:///C:/project becomes /C:/project.
		if len(path) >= 3 && path[0] == '/' && path[2] == ':' {
			path = path[1:]
		}
	}
	normalized, normalizedOK := tool_policy.permission_normalize_absolute_path(
		path,
		context.temp_allocator,
	)
	if !normalizedOK ||
	   normalized == projectRoot ||
	   !tool_policy.permission_path_is_within_project(projectRoot, normalized) {
		return uri
	}
	return strings.trim_left(normalized[len(projectRoot):], "/\\")
}

last_path_segment :: proc(path: string) -> string {
	index := strings.last_index_any(path, "/\\")
	if index < 0 {
		return path
	}
	return path[index + 1:]
}
