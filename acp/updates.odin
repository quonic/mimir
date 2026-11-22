package acp

import "../session"
import "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

// Turns session events into ACP session/update notifications, permission requests and prompt
// responses (ADR-0003, Events, Approvals and Subagents).

handle_session_event :: proc(conn: ^Connection, entry: ^ACP_Session, event: session.Session_Event) {
	switch value in event {
	case session.Message_Delta:
		if value.subagentDepth == 0 {
			if value.text == "" {
				return
			}
			connection_send_session_update(
				conn,
				entry,
				json_object(
					{"sessionUpdate", "agent_message_chunk"},
					{"content", json_object({"type", "text"}, {"text", json_text(value.text)})},
				),
			)
			return
		}
		// Subagent text is content of its run_subagent tool call. It is sent at most once per
		// tick, because each tool_call_update replaces the whole content.
		if view := find_tool_call(entry, value.parentToolCallID); view != nil {
			strings.write_string(&view.subagentText, value.text)
			view.subagentDirty = true
		}
	case session.Thinking_Changed:
	case session.Usage_Updated:
		// usage_update needs a size; without a known context window Mimir sends nothing.
		if value.contextWindowTokens <= 0 {
			return
		}
		used := 0
		if value.usage.hasInputTokens {
			used = value.usage.inputTokens
		}
		connection_send_session_update(
			conn,
			entry,
			json_object(
				{"sessionUpdate", "usage_update"},
				{"used", json_integer(used)},
				{"size", json_integer(value.contextWindowTokens)},
			),
		)
	case session.Tool_Call_Started:
		handle_tool_call_started(conn, entry, value)
	case session.Tool_Call_Updated:
		handle_tool_call_updated(conn, entry, value)
	case session.Approval_Requested:
		handle_approval_requested(conn, entry, value)
	case session.Approval_Safety_Updated:
		handle_approval_safety_updated(conn, entry, value)
	case session.Approval_Resolved:
		handle_approval_resolved(conn, entry, value)
	case session.Subagent_Started:
		view := find_tool_call(entry, value.parentToolCallID)
		if view == nil {
			return
		}
		delete(view.subagentTask, conn.allocator)
		view.subagentTask = strings.clone(value.task, conn.allocator)
		view.status = .Running
		send_tool_call_update(conn, entry, view)
	case session.Subagent_Finished:
		view := find_tool_call(entry, value.parentToolCallID)
		if view == nil {
			return
		}
		result := value.result
		if value.failed && value.errorText != "" {
			result = fmt.tprintf("%s\n%s", value.errorText, value.result)
		}
		delete(view.subagentResult, conn.allocator)
		view.subagentResult = strings.clone(result, conn.allocator)
		view.subagentDirty = false
		// The session sends no Tool_Call_Updated for run_subagent when the subagent ends, so
		// the final status comes from this event.
		view.status = .Failed if value.failed else .Completed
		view.final = true
		send_tool_call_update(conn, entry, view)
	case session.Turn_Ended:
		handle_turn_ended(conn, entry, value)
	case session.Notice:
		level := Log_Level.Info
		switch value.severity {
		case .Info:
			level = .Info
		case .Warning:
			level = .Warning
		case .Error:
			level = .Error
		}
		connection_log(conn, level, "%s: %s", entry.id, value.text)
		if conn.clientNotices {
			send_notice(conn, entry, value.severity, value.text)
		}
	}
}

send_notice :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	severity: session.Notice_Severity,
	text: string,
) {
	severityText := "info"
	switch severity {
	case .Info:
		severityText = "info"
	case .Warning:
		severityText = "warning"
	case .Error:
		severityText = "error"
	}
	connection_send_session_update(
		conn,
		entry,
		json_object(
			{"sessionUpdate", "notice"},
			{"severity", json.String(severityText)},
			{"title", json_text(text)},
		),
	)
}

handle_turn_ended :: proc(conn: ^Connection, entry: ^ACP_Session, ended: session.Turn_Ended) {
	if !entry.promptOpen {
		acp_session_clear_turn(conn, entry)
		return
	}
	switch ended.reason {
	case .Completed:
		end_prompt(conn, entry, json_object({"stopReason", "end_turn"}), true)
	case .Canceled:
		end_prompt(conn, entry, json_object({"stopReason", "cancelled"}), true)
	case .Failed:
		// After session/cancel, an aborted request can surface as a failure. ACP requires
		// the stop reason cancelled then.
		if entry.cancelRequested {
			end_prompt(conn, entry, json_object({"stopReason", "cancelled"}), true)
		} else {
			message := ended.errorText
			if message == "" {
				message = "The turn failed"
			}
			end_prompt(conn, entry, nil, false, ERROR_INTERNAL, message)
		}
	}
}

find_tool_call :: proc(entry: ^ACP_Session, toolCallID: string) -> ^Tool_Call_View {
	if toolCallID == "" {
		return nil
	}
	for index := len(entry.toolCalls) - 1; index >= 0; index -= 1 {
		if entry.toolCalls[index].toolCallID == toolCallID {
			return entry.toolCalls[index]
		}
	}
	return nil
}

// Returns the ACP ToolKind of a tool.
tool_kind :: proc(toolID: string) -> string {
	switch toolID {
	case "read_file", "read_skill", "list_directory", "get_file_info":
		return "read"
	case "write_file", "replace_string_in_file", "patch_file":
		return "edit"
	case "run_in_terminal":
		return "execute"
	case "grep_search", "search_code", "find_code":
		return "search"
	}
	return "other"
}

// Returns the ACP ToolCallStatus of a session tool call status.
tool_status_text :: proc(status: session.Tool_Call_Status) -> string {
	switch status {
	case .Awaiting_Approval:
		return "pending"
	case .Running:
		return "in_progress"
	case .Completed:
		return "completed"
	case .Failed, .Denied:
		return "failed"
	}
	return "failed"
}

tool_status_is_final :: proc(status: session.Tool_Call_Status) -> bool {
	return status == .Completed || status == .Failed || status == .Denied
}

// Returns the path argument of a tool call (file_path or directory_path), or "".
tool_call_path_argument :: proc(arguments: string) -> string {
	value, err := json.parse_string(arguments, .JSON, true, context.temp_allocator)
	if err != .None {
		return ""
	}
	object, isObject := value.(json.Object)
	if !isObject {
		return ""
	}
	if path, ok := json_get_string(object, "file_path"); ok && path != "" {
		return path
	}
	if path, ok := json_get_string(object, "directory_path"); ok && path != "" {
		return path
	}
	return ""
}

handle_tool_call_started :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	started: session.Tool_Call_Started,
) {
	allocator := conn.allocator
	view := new(Tool_Call_View, allocator)
	view.toolCallID = strings.clone(started.toolCallID, allocator)
	view.toolID = strings.clone(started.toolID, allocator)
	view.arguments = strings.clone(started.arguments, allocator)
	view.status = .Awaiting_Approval
	view.subagentText = strings.builder_make(allocator)
	pathArgument := tool_call_path_argument(started.arguments)
	if pathArgument != "" {
		if resolved, ok := tool_policy.permission_resolve_project_path(
			entry.projectRoot,
			pathArgument,
			allocator,
		); ok {
			view.path = resolved
		}
	}
	target := started.target
	if target == "" {
		target = pathArgument
	}
	if target == "" || started.toolID == "run_subagent" {
		view.title = strings.clone(started.toolID, allocator)
	} else {
		view.title = strings.concatenate({started.toolID, ": ", target}, allocator)
	}
	append(&entry.toolCalls, view)

	toolCall := tool_call_object(view, true)
	object := toolCall.(json.Object)
	object["sessionUpdate"] = "tool_call"
	connection_send_session_update(conn, entry, object)
}

handle_tool_call_updated :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	updated: session.Tool_Call_Updated,
) {
	view := find_tool_call(entry, updated.toolCallID)
	if view == nil || view.final {
		// For example a tool that finished after the turn was canceled and answered.
		connection_log(
			conn,
			.Debug,
			"%s: dropped an update of tool call %s",
			entry.id,
			updated.toolCallID,
		)
		return
	}
	if updated.status == view.status && updated.output == "" && updated.diff.path == "" {
		// Nothing new, for example the first pending status right after tool_call.
		return
	}
	view.status = updated.status
	if updated.output != "" {
		delete(view.output, conn.allocator)
		view.output = strings.clone(updated.output, conn.allocator)
	}
	if updated.diff.path != "" {
		session.file_diff_destroy(&view.diff, conn.allocator)
		view.diff = session.file_diff_copy(updated.diff, conn.allocator)
	}
	// The run_subagent call stays open until Subagent_Finished.
	if tool_status_is_final(updated.status) {
		view.final = true
	}
	send_tool_call_update(conn, entry, view)
}

// Returns the ACP fields of a tool call: toolCallId, status, content and, when full is true,
// title, kind, locations and rawInput.
tool_call_object :: proc(view: ^Tool_Call_View, full: bool) -> json.Value {
	object := json_object(
		{"toolCallId", json.String(view.toolCallID)},
		{"status", json.String(tool_status_text(view.status))},
	).(json.Object)
	content := tool_call_content(view)
	if len(content) > 0 {
		object["content"] = content
	}
	if full {
		object["title"] = json_text(view.title)
		object["kind"] = json.String(tool_kind(view.toolID))
		if view.path != "" {
			object["locations"] = json_array(json_object({"path", json_text(view.path)}))
		}
		rawInput, parseErr := json.parse_string(view.arguments, .JSON, true, context.temp_allocator)
		if parseErr != .None {
			rawInput = json_text(view.arguments)
		}
		object["rawInput"] = rawInput
	}
	return object
}

text_content_block :: proc(text: string) -> json.Value {
	return json_object(
		{"type", "content"},
		{"content", json_object({"type", "text"}, {"text", json_text(text)})},
	)
}

// Returns the whole content of a tool call: the safety verdict, the subagent task, text and
// result, the output, and the file diff.
tool_call_content :: proc(view: ^Tool_Call_View) -> json.Array {
	content := make(json.Array, 0, 4, context.temp_allocator)
	if view.safetyText != "" {
		append(&content, text_content_block(view.safetyText))
	}
	if view.subagentTask != "" {
		append(&content, text_content_block(fmt.tprintf("Task: %s", view.subagentTask)))
	}
	if subagentText := strings.to_string(view.subagentText); subagentText != "" {
		append(&content, text_content_block(subagentText))
	}
	if view.subagentResult != "" {
		append(&content, text_content_block(view.subagentResult))
	}
	if view.output != "" {
		append(&content, text_content_block(view.output))
	} else if view.status == .Denied {
		append(&content, text_content_block("Permission denied."))
	}
	if view.diff.path != "" {
		oldText: json.Value = nil
		if !view.diff.newFile {
			oldText = json_text(view.diff.oldText)
		}
		append(
			&content,
			json_object(
				{"type", "diff"},
				{"path", json_text(view.diff.path)},
				{"oldText", oldText},
				{"newText", json_text(view.diff.newText)},
			),
		)
	}
	return content
}

send_tool_call_update :: proc(conn: ^Connection, entry: ^ACP_Session, view: ^Tool_Call_View) {
	update := tool_call_object(view, false)
	object := update.(json.Object)
	object["sessionUpdate"] = "tool_call_update"
	connection_send_session_update(conn, entry, object)
}

// Sends the subagent text that arrived since the last tick.
flush_subagent_text :: proc(conn: ^Connection, entry: ^ACP_Session) {
	for view in entry.toolCalls {
		if view.subagentDirty {
			view.subagentDirty = false
			send_tool_call_update(conn, entry, view)
		}
	}
}

// Returns the text of a safety state for the tool call content, or "".
safety_text :: proc(safety: session.Approval_Safety) -> string {
	switch safety.status {
	case .Not_Checked:
		return ""
	case .Checking:
		return "Safety check: running."
	case .Unavailable:
		return "Safety check: unavailable."
	case .Checked:
		reason := safety.response
		if lineEnd := strings.index_byte(reason, '\n'); lineEnd >= 0 {
			reason = reason[:lineEnd]
		}
		if separator := strings.index_byte(reason, '|'); separator >= 0 {
			reason = reason[separator + 1:]
		}
		reason = strings.trim_space(reason)
		verdict := "no clear verdict"
		switch safety.verdict {
		case .Safe:
			verdict = "safe"
		case .Risky:
			verdict = "risky"
		case .Unclear:
			verdict = "unclear"
		case .Invalid:
			return "Safety check: no clear verdict."
		}
		if reason == "" {
			return fmt.tprintf("Safety check: %s.", verdict)
		}
		return fmt.tprintf("Safety check: %s. %s", verdict, reason)
	}
	return ""
}

set_safety_text :: proc(conn: ^Connection, view: ^Tool_Call_View, safety: session.Approval_Safety) {
	if view == nil {
		return
	}
	delete(view.safetyText, conn.allocator)
	view.safetyText = strings.clone(safety_text(safety), conn.allocator)
	view.safetyChecking = safety.status == .Checking
}

handle_approval_requested :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	requested: session.Approval_Requested,
) {
	hold := &entry.approval
	approval_hold_clear(hold, conn.allocator)
	hold.active = true
	hold.toolCallID = strings.clone(requested.toolCallID, conn.allocator)
	hold.action = session.permission_action_copy(requested.action, conn.allocator)
	set_safety_text(conn, find_tool_call(entry, requested.toolCallID), requested.safety)
	// Under Approve_Safe the session may approve the call by itself when the verdict comes, so
	// the client is not asked until then (ADR-0002, Consequences).
	if entry.session.approvalMethod == .Approve_Safe && requested.safety.status == .Checking {
		hold.held = true
		hold.heldSince = time.tick_now()
		return
	}
	send_permission_request(conn, entry)
}

handle_approval_safety_updated :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	updated: session.Approval_Safety_Updated,
) {
	view := find_tool_call(entry, updated.toolCallID)
	set_safety_text(conn, view, updated.safety)
	hold := &entry.approval
	if !hold.active || hold.toolCallID != updated.toolCallID {
		return
	}
	// Under Approve_Safe a safe verdict approves the call in the same poll, and the
	// Approval_Resolved event that follows drops the hold. So the request is not sent here:
	// connection_tick sends it after the events of the poll if the hold is still active.
	if hold.held {
		hold.verdictReady = true
		return
	}
	if hold.requestID != 0 && view != nil {
		// An open request cannot change, so the verdict goes to the tool call.
		send_tool_call_update(conn, entry, view)
	}
}

handle_approval_resolved :: proc(
	conn: ^Connection,
	entry: ^ACP_Session,
	resolved: session.Approval_Resolved,
) {
	if view := find_tool_call(entry, resolved.toolCallID); view != nil && view.safetyChecking {
		// The safety check stops with the approval, so "running" would stay forever.
		delete(view.safetyText, conn.allocator)
		view.safetyText = ""
		view.safetyChecking = false
	}
	hold := &entry.approval
	if !hold.active || hold.toolCallID != resolved.toolCallID {
		return
	}
	if hold.requestID != 0 {
		// The session settled the call while the client still shows the request. After
		// session/cancel the client answers it with cancelled by itself.
		if !entry.cancelRequested {
			if request, found := &conn.outbound[hold.requestID]; found {
				request.cancelSent = true
			}
			connection_send_notification(
				conn,
				"$/cancel_request",
				json_object({"requestId", json.Integer(hold.requestID)}),
			)
		}
	}
	approval_hold_clear(hold, conn.allocator)
}

// Maps an ACP option ID to an approval choice. The grant options are valid only when they
// were offered.
permission_option_choice :: proc(
	optionID: string,
	offeredGrants: bool,
) -> (
	session.Approval_Choice,
	bool,
) {
	switch optionID {
	case "allow-once":
		return .Allow_Once, true
	case "reject-once":
		return .Deny, true
	case "allow-session":
		return .Allow_Session, offeredGrants
	case "allow-always":
		return .Allow_Always, offeredGrants
	}
	return .Deny, false
}

// Returns the scope text of the grant that the action allows, for the option names.
grant_scope_text :: proc(action: tool_policy.Permission_Action) -> (string, bool) {
	grant, grantOK := tool_policy.tool_dispatch_grant_from_action(action, context.temp_allocator)
	if !grantOK {
		return "", false
	}
	switch grant.kind {
	case .Directory_Subtree:
		return fmt.tprintf("writes in %s", grant.directory), true
	case .Command_Prefix:
		return fmt.tprintf("commands starting with %s", grant.command), true
	}
	return "", false
}

permission_option :: proc(optionID, name, kind: string) -> json.Value {
	return json_object(
		{"optionId", json.String(optionID)},
		{"name", json_text(name)},
		{"kind", json.String(kind)},
	)
}

// Sends session/request_permission for the pending approval of entry.
send_permission_request :: proc(conn: ^Connection, entry: ^ACP_Session) {
	hold := &entry.approval
	view := find_tool_call(entry, hold.toolCallID)
	if !hold.active || view == nil {
		return
	}
	hold.held = false
	hold.verdictReady = false
	conn.nextRequestID += 1
	requestID := conn.nextRequestID
	hold.requestID = requestID

	options := make(json.Array, 0, 4, context.temp_allocator)
	append(&options, permission_option("allow-once", "Allow once", "allow_once"))
	scope, scopeOK := grant_scope_text(hold.action)
	hold.offeredGrants = scopeOK && !hold.onceOnly
	if hold.offeredGrants {
		append(
			&options,
			permission_option(
				"allow-session",
				fmt.tprintf("Allow for this session: %s", scope),
				"allow_always",
			),
			permission_option(
				"allow-always",
				fmt.tprintf("Always allow: %s", scope),
				"allow_always",
			),
		)
	}
	append(&options, permission_option("reject-once", "Deny", "reject_once"))

	conn.outbound[requestID] = Outbound_Request {
		sessionID  = strings.clone(entry.id, conn.allocator),
		toolCallID = strings.clone(hold.toolCallID, conn.allocator),
	}
	connection_send(
		conn,
		json_object(
			{"jsonrpc", "2.0"},
			{"id", json.Integer(requestID)},
			{"method", "session/request_permission"},
			{
				"params",
				json_object(
					{"sessionId", json.String(entry.id)},
					{"toolCall", tool_call_object(view, true)},
					{"options", options},
				),
			},
		),
	)
}
