package acp

import "../session"
import "../settings"
import "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

// The ACP front end: Mimir as an Agent Client Protocol (v1) agent over stdio. A Connection
// holds the protocol state and maps ACP session IDs to sessions. See ADR-0003.
//
// The connection is not a callback sink: it handles inbound messages, polls its sessions in
// connection_tick, and appends outbound lines to outbox. run (run.odin) reads stdin and writes
// the outbox to stdout. Tests call connection_handle_line and connection_tick directly.

ACP_PROTOCOL_VERSION :: 1
// A stdin line longer than this is dropped and answered with a parse error.
ACP_MAX_MESSAGE_BYTES :: 16 * 1024 * 1024
// How long a permission request waits for the safety verdict under Approve_Safe.
ACP_SAFETY_HOLD_TIMEOUT_MS :: 15_000
// How long session/close and shutdown wait for a canceled turn to end.
ACP_TURN_END_TIMEOUT_MS :: 2_000
// The version in agentInfo. Release builds can set it with -define:MIMIR_VERSION=<version>.
MIMIR_VERSION :: #config(MIMIR_VERSION, "dev")

// JSON-RPC and ACP error codes (ACP Errors page).
ERROR_PARSE :: -32700
ERROR_INVALID_REQUEST :: -32600
ERROR_METHOD_NOT_FOUND :: -32601
ERROR_INVALID_PARAMS :: -32602
ERROR_INTERNAL :: -32603
ERROR_RESOURCE_NOT_FOUND :: -32002
// Mimir's own codes use -31000 to -31099.
ERROR_SESSION_BUSY :: -31001
ERROR_NO_USABLE_MODEL :: -31002

Log_Level :: enum int {
	Debug = 0,
	Info,
	Warning,
	Error,
}

// Receives the log lines of a connection. nil writes them to stderr.
Log_Sink :: #type proc(data: rawptr, level: Log_Level, text: string)

Connection :: struct {
	allocator:         mem.Allocator,
	// Shared with every session. It must stay at the same address.
	config:            ^settings.Mimir_Config,
	configHome:        string,
	initialized:       bool,
	// The client capabilities that Mimir reads.
	clientNotices:     bool,
	clientSubagents:   bool,
	sessions:          map[string]^ACP_Session,
	nextSessionNumber: int,
	// The ID of Mimir's last request to the client.
	nextRequestID:     i64,
	// Open session/request_permission requests, by JSON-RPC ID.
	outbound:          map[i64]Outbound_Request,
	// Lines to write to stdout, owned by allocator.
	outbox:            [dynamic]string,
	// ACP_SAFETY_HOLD_TIMEOUT_MS; tests make it shorter.
	safetyHoldTimeout: time.Duration,
	turnEndTimeout:    time.Duration,
	logSink:           Log_Sink,
	logData:           rawptr,
}

// A session/request_permission request that waits for the client's response.
Outbound_Request :: struct {
	sessionID:  string,
	toolCallID: string,
	// Mimir sent $/cancel_request for it.
	cancelSent: bool,
}

ACP_Session :: struct {
	id:              string,
	session:         ^session.Session,
	projectRoot:     string,
	// The ID of the open session/prompt request, valid while promptOpen.
	promptID:        json.Value,
	promptOpen:      bool,
	cancelRequested: bool,
	// The tool calls of the current turn, in order.
	toolCalls:       [dynamic]^Tool_Call_View,
	approval:        Approval_Hold,
	// session/close waits for the canceled turn to end.
	closeRequested:  bool,
	closeRequestID:  json.Value,
	closeStarted:    time.Tick,
}

// What the client has seen of one tool call. Every tool_call_update sends the whole content.
Tool_Call_View :: struct {
	toolCallID:     string,
	toolID:         string,
	title:          string,
	// The absolute path of a tool whose target is a path, or "".
	path:           string,
	arguments:      string,
	status:         session.Tool_Call_Status,
	final:          bool,
	output:         string,
	diff:           session.File_Diff,
	// The safety verdict text of the approval, or "".
	safetyText:     string,
	// The safety classifier still runs for the approval.
	safetyChecking: bool,
	// For run_subagent: the task, the streamed subagent text and the result.
	subagentTask:   string,
	subagentText:   strings.Builder,
	subagentResult: string,
	// New subagent text that the client has not seen.
	subagentDirty:  bool,
}

// The pending approval of a session, as the front end sees it.
Approval_Hold :: struct {
	active:        bool,
	toolCallID:    string,
	action:        tool_policy.Permission_Action,
	// Under Approve_Safe, the request waits for the safety verdict.
	held:          bool,
	heldSince:     time.Tick,
	// The safety verdict arrived while the request was held.
	verdictReady:  bool,
	// The JSON-RPC ID of the open session/request_permission, or 0.
	requestID:     i64,
	// The last request offered the allow-session and allow-always options.
	offeredGrants: bool,
	// A grant could not be saved, so only one-time options are offered.
	onceOnly:      bool,
}

connection_init :: proc(
	config: ^settings.Mimir_Config,
	configHome: string,
	allocator := context.allocator,
) -> Connection {
	return Connection {
		allocator = allocator,
		config = config,
		configHome = strings.clone(configHome, allocator),
		sessions = make(map[string]^ACP_Session, allocator),
		outbound = make(map[i64]Outbound_Request, allocator),
		outbox = make([dynamic]string, 0, 16, allocator),
		safetyHoldTimeout = ACP_SAFETY_HOLD_TIMEOUT_MS * time.Millisecond,
		turnEndTimeout = ACP_TURN_END_TIMEOUT_MS * time.Millisecond,
	}
}

connection_destroy :: proc(conn: ^Connection) {
	for _, entry in conn.sessions {
		acp_session_destroy(conn, entry)
	}
	delete(conn.sessions)
	for _, &request in conn.outbound {
		outbound_request_destroy(&request, conn.allocator)
	}
	delete(conn.outbound)
	connection_clear_outbox(conn)
	delete(conn.outbox)
	delete(conn.configHome, conn.allocator)
	conn^ = {}
}

// Frees the lines of the outbox after they were written.
connection_clear_outbox :: proc(conn: ^Connection) {
	for line in conn.outbox {
		delete(line, conn.allocator)
	}
	clear(&conn.outbox)
}

outbound_request_destroy :: proc(request: ^Outbound_Request, allocator: mem.Allocator) {
	delete(request.sessionID, allocator)
	delete(request.toolCallID, allocator)
	request^ = {}
}

acp_session_destroy :: proc(conn: ^Connection, entry: ^ACP_Session) {
	allocator := conn.allocator
	session.session_destroy(entry.session)
	acp_session_clear_turn(conn, entry)
	delete(entry.toolCalls)
	approval_hold_clear(&entry.approval, allocator)
	json_request_id_destroy(&entry.promptID, allocator)
	json_request_id_destroy(&entry.closeRequestID, allocator)
	delete(entry.id, allocator)
	delete(entry.projectRoot, allocator)
	free(entry, allocator)
}

// Frees the tool calls of the turn.
acp_session_clear_turn :: proc(conn: ^Connection, entry: ^ACP_Session) {
	for view in entry.toolCalls {
		tool_call_view_destroy(view, conn.allocator)
	}
	clear(&entry.toolCalls)
}

tool_call_view_destroy :: proc(view: ^Tool_Call_View, allocator: mem.Allocator) {
	delete(view.toolCallID, allocator)
	delete(view.toolID, allocator)
	delete(view.title, allocator)
	delete(view.path, allocator)
	delete(view.arguments, allocator)
	delete(view.output, allocator)
	session.file_diff_destroy(&view.diff, allocator)
	delete(view.safetyText, allocator)
	delete(view.subagentTask, allocator)
	strings.builder_destroy(&view.subagentText)
	delete(view.subagentResult, allocator)
	free(view, allocator)
}

approval_hold_clear :: proc(hold: ^Approval_Hold, allocator: mem.Allocator) {
	delete(hold.toolCallID, allocator)
	session.permission_action_copy_destroy(&hold.action, allocator)
	hold^ = {}
}

connection_log :: proc(conn: ^Connection, level: Log_Level, format: string, args: ..any) {
	text := fmt.tprintf(format, ..args)
	if conn.logSink != nil {
		conn.logSink(conn.logData, level, text)
		return
	}
	label := "info"
	switch level {
	case .Debug:
		label = "debug"
	case .Info:
		label = "info"
	case .Warning:
		label = "warning"
	case .Error:
		label = "error"
	}
	fmt.eprintfln("mimir acp [%s] %s", label, text)
}

// Reports whether a session has an active turn, a held approval or a pending close, so the
// main loop polls more often.
connection_busy :: proc(conn: ^Connection) -> bool {
	for _, entry in conn.sessions {
		if entry.promptOpen || entry.approval.held || entry.closeRequested {
			return true
		}
		if session.session_turn_active(entry.session) ||
		   session.session_tool_running(entry.session) {
			return true
		}
	}
	return false
}

// Appends one JSON-RPC message to the outbox.
connection_send :: proc(conn: ^Connection, message: json.Value) {
	line, ok := json_marshal_line(message, conn.allocator)
	if !ok {
		connection_log(conn, .Error, "could not encode an outbound message")
		return
	}
	append(&conn.outbox, line)
}

connection_send_result :: proc(conn: ^Connection, id: json.Value, result: json.Value) {
	connection_send(
		conn,
		json_object({"jsonrpc", "2.0"}, {"id", id}, {"result", result}),
	)
}

connection_send_error :: proc(
	conn: ^Connection,
	id: json.Value,
	code: int,
	message: string,
	data: json.Value = nil,
) {
	errorObject := json_object({"code", json_integer(code)}, {"message", json_text(message)})
	if data != nil {
		object := errorObject.(json.Object)
		object["data"] = data
		errorObject = object
	}
	connection_send(
		conn,
		json_object({"jsonrpc", "2.0"}, {"id", id}, {"error", errorObject}),
	)
}

connection_send_notification :: proc(conn: ^Connection, method: string, params: json.Value) {
	connection_send(
		conn,
		json_object({"jsonrpc", "2.0"}, {"method", json.String(method)}, {"params", params}),
	)
}

connection_send_session_update :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	update: json.Value,
) {
	connection_send_notification(
		conn,
		"session/update",
		json_object({"sessionId", json.String(entry.id)}, {"update", update}),
	)
}

// Handles one inbound line from stdin. A trailing "\r" is ignored.
connection_handle_line :: proc(conn: ^Connection, line: string) {
	text := strings.trim_right(line, "\r")
	if strings.trim_space(text) == "" {
		return
	}
	value, parseErr := json.parse_string(text, .JSON, true, context.temp_allocator)
	if parseErr != .None {
		connection_send_error(conn, nil, ERROR_PARSE, "Parse error")
		return
	}
	#partial switch message in value {
	case json.Object:
		connection_handle_message(conn, message)
	case json.Array:
		connection_send_error(conn, nil, ERROR_INVALID_REQUEST, "Batch requests are not supported")
	case:
		connection_send_error(conn, nil, ERROR_INVALID_REQUEST, "Invalid request")
	}
}

// Answers a stdin line that was longer than ACP_MAX_MESSAGE_BYTES.
connection_handle_oversized_line :: proc(conn: ^Connection) {
	connection_log(conn, .Warning, "dropped a message longer than %d bytes", ACP_MAX_MESSAGE_BYTES)
	connection_send_error(conn, nil, ERROR_PARSE, "Message too long")
}

connection_handle_message :: proc(conn: ^Connection, message: json.Object) {
	id, hasID := message["id"]
	if hasID && !json_is_request_id(id) {
		connection_send_error(conn, nil, ERROR_INVALID_REQUEST, "Invalid request ID")
		return
	}
	replyID: json.Value = nil
	if hasID {
		replyID = id
	}
	version, versionOK := json_get_string(message, "jsonrpc")
	if !versionOK || version != "2.0" {
		connection_send_error(conn, replyID, ERROR_INVALID_REQUEST, "Not a JSON-RPC 2.0 message")
		return
	}
	if methodValue, hasMethod := message["method"]; hasMethod {
		method, isString := methodValue.(json.String)
		if !isString {
			connection_send_error(conn, replyID, ERROR_INVALID_REQUEST, "Invalid method")
			return
		}
		params, _ := message["params"]
		if hasID {
			connection_handle_request(conn, id, string(method), params)
		} else {
			connection_handle_notification(conn, string(method), params)
		}
		return
	}
	_, hasResult := message["result"]
	_, hasError := message["error"]
	if hasID && (hasResult || hasError) {
		connection_handle_response(conn, id, message)
		return
	}
	connection_send_error(conn, replyID, ERROR_INVALID_REQUEST, "Invalid request")
}

connection_handle_request :: proc(
	conn: ^Connection,
	id: json.Value,
	method: string,
	params: json.Value,
) {
	if !conn.initialized && method != "initialize" {
		connection_send_error(conn, id, ERROR_INVALID_REQUEST, "The connection is not initialized")
		return
	}
	switch method {
	case "initialize":
		handle_initialize(conn, id, params)
	case "session/new":
		handle_session_new(conn, id, params)
	case "session/prompt":
		handle_session_prompt(conn, id, params)
	case "session/close":
		handle_session_close(conn, id, params)
	case:
		// Includes authenticate, logout, session/load, session/resume, session/list,
		// session/delete, session/set_mode, session/set_config_option and every extension
		// method: Mimir does not advertise them.
		connection_send_error(conn, id, ERROR_METHOD_NOT_FOUND, "Method not found")
	}
}

connection_handle_notification :: proc(conn: ^Connection, method: string, params: json.Value) {
	if !conn.initialized {
		connection_log(conn, .Debug, "ignored %s before initialize", method)
		return
	}
	switch method {
	case "session/cancel":
		handle_session_cancel(conn, params)
	case "$/cancel_request":
		handle_cancel_request(conn, params)
	case:
		connection_log(conn, .Debug, "ignored notification %s", method)
	}
}

// Handles the client's response to a session/request_permission request.
connection_handle_response :: proc(conn: ^Connection, id: json.Value, message: json.Object) {
	requestID, isInteger := id.(json.Integer)
	if !isInteger {
		connection_log(conn, .Warning, "ignored a response to an unknown request")
		return
	}
	request, found := conn.outbound[i64(requestID)]
	if !found {
		connection_log(conn, .Warning, "ignored a response to unknown request %d", requestID)
		return
	}
	delete_key(&conn.outbound, i64(requestID))
	defer outbound_request_destroy(&request, conn.allocator)
	entry, entryOK := conn.sessions[request.sessionID]
	if !entryOK || entry.closeRequested {
		connection_log(conn, .Debug, "ignored a permission response of a closed session")
		return
	}
	hold := &entry.approval
	if !hold.active || hold.toolCallID != request.toolCallID || hold.requestID != i64(requestID) {
		connection_log(
			conn,
			.Debug,
			"ignored a stale permission response for tool call %s",
			request.toolCallID,
		)
		return
	}
	hold.requestID = 0

	choice := session.Approval_Choice.Deny
	if _, hasError := message["error"]; hasError {
		connection_log(conn, .Warning, "permission request %d failed; denying", requestID)
	} else if result, resultOK := json_get_object(message, "result"); resultOK {
		outcome, outcomeOK := json_get_object(result, "outcome")
		kind, kindOK := json_get_string(outcome, "outcome")
		switch {
		case !outcomeOK || !kindOK:
			connection_log(conn, .Warning, "unknown permission outcome; denying")
		case kind == "selected":
			optionID, _ := json_get_string(outcome, "optionId")
			optionChoice, optionOK := permission_option_choice(optionID, hold.offeredGrants)
			if optionOK {
				choice = optionChoice
			} else {
				connection_log(conn, .Warning, "unknown permission option %q; denying", optionID)
			}
		case kind == "cancelled":
			if entry.cancelRequested {
				// session_cancel_turn settles the approval.
				return
			}
		case:
			connection_log(conn, .Warning, "unknown permission outcome %q; denying", kind)
		}
	} else {
		connection_log(conn, .Warning, "permission response without a result; denying")
	}

	resolveErr := session.session_resolve_approval(entry.session, request.toolCallID, choice)
	#partial switch resolveErr {
	case .None:
	case .Approval_Not_Applied:
		// The grant was not added or saved. The approval stays pending: ask again with only
		// the one-time options.
		connection_log(conn, .Error, "permission grant was not saved; asking again")
		hold.onceOnly = true
		send_permission_request(conn, entry)
	case .No_Pending_Approval, .Unknown_Tool_Call:
		connection_log(conn, .Debug, "permission response for a settled tool call")
	case:
		connection_log(conn, .Warning, "permission response not applied: %v", resolveErr)
	}
}

// Polls every session and turns its events into outbound messages. It also sends held
// permission requests whose time ran out and finishes pending closes.
connection_tick :: proc(conn: ^Connection) {
	ids := make([dynamic]string, 0, len(conn.sessions), context.temp_allocator)
	for id in conn.sessions {
		append(&ids, id)
	}
	for id in ids {
		entry, ok := conn.sessions[id]
		if !ok {
			continue
		}
		_ = session.session_poll(entry.session)
		for {
			event, eventOK := session.session_next_event(entry.session)
			if !eventOK {
				break
			}
			handle_session_event(conn, entry, event)
			session.session_event_destroy(&event, entry.session.allocator)
		}
		flush_subagent_text(conn, entry)
		hold := &entry.approval
		if hold.active && hold.held {
			if hold.verdictReady {
				send_permission_request(conn, entry)
			} else if time.tick_since(hold.heldSince) >= conn.safetyHoldTimeout {
				connection_log(conn, .Info, "%s: safety check is slow; asking the client", entry.id)
				send_permission_request(conn, entry)
			}
		}
		if entry.closeRequested {
			if !entry.promptOpen || time.tick_since(entry.closeStarted) >= conn.turnEndTimeout {
				finish_session_close(conn, entry)
			}
		}
	}
}

// Ends the connection: cancels every active turn, waits up to turnEndTimeout for the turns to
// end, answers the open prompts and destroys the sessions. The outbox keeps the last messages.
connection_shutdown :: proc(conn: ^Connection) {
	for _, entry in conn.sessions {
		if entry.promptOpen {
			entry.cancelRequested = true
			_ = session.session_cancel_turn(entry.session)
		}
	}
	start := time.tick_now()
	for {
		connection_tick(conn)
		open := false
		for _, entry in conn.sessions {
			if entry.promptOpen {
				open = true
			}
		}
		if !open || time.tick_since(start) >= conn.turnEndTimeout {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	for id, entry in conn.sessions {
		if entry.promptOpen {
			end_prompt(conn, entry, json_object({"stopReason", "cancelled"}), true)
		}
		acp_session_destroy(conn, entry)
		_ = id
	}
	clear(&conn.sessions)
}
