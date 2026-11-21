#+vet explicit-allocators
package session

import "../ai"
import "../approval_safety"
import "../tool_policy"
import "core:mem"
import "core:strings"

// Session events tell a front end what happened in a session. They carry data, not display
// text: the front end formats them. A front end pulls them with session_next_event and frees
// each one with session_event_destroy. A tool call and its approval are identified by the tool
// call ID of the model.

Tool_Call_Status :: enum int {
	Awaiting_Approval = 0,
	Running,
	Completed,
	Failed,
	Denied,
}

// Streamed assistant text. subagentDepth is 0 for the main agent and 1 or more for a subagent.
Message_Delta :: struct {
	text:             string,
	subagentDepth:    int,
	// The run_subagent tool call of the subagent that sends the text, or "" for the main agent.
	parentToolCallID: string,
}

Thinking_Changed :: struct {
	thinking:      bool,
	subagentDepth: int,
}

// The token usage of the turn. usage.inputTokens is the current context usage: the input
// tokens of the latest request. contextWindowTokens is 0 when the context window size is
// unknown. A new turn sends an event with empty usage first.
Usage_Updated :: struct {
	usage:               ai.Chat_Usage,
	contextWindowTokens: int,
}

// The model requested a tool call. A Tool_Call_Updated event with its first status follows.
Tool_Call_Started :: struct {
	toolCallID: string,
	toolID:     string,
	// The field of the call that a front end shows, for example the path of read_file.
	target:     string,
	// The raw JSON arguments from the model.
	arguments:  string,
}

Tool_Call_Updated :: struct {
	toolCallID: string,
	status:     Tool_Call_Status,
	output:     string,
}

Approval_Safety_Status :: enum int {
	// The approval method does not use the safety classifier for this call.
	Not_Checked = 0,
	// The safety classifier runs.
	Checking,
	// No safety model is available, or the classifier could not run.
	Unavailable,
	// The safety classifier finished. verdict and response hold its answer.
	Checked,
}

Approval_Safety :: struct {
	status:   Approval_Safety_Status,
	verdict:  approval_safety.Verdict,
	// The raw response of the safety classifier.
	response: string,
}

// A tool call waits for an approval choice. Answer it with session_resolve_approval.
Approval_Requested :: struct {
	toolCallID: string,
	action:     tool_policy.Permission_Action,
	safety:     Approval_Safety,
}

Approval_Safety_Updated :: struct {
	toolCallID: string,
	safety:     Approval_Safety,
}

// The pending approval was answered, by the front end or by the approval method.
Approval_Resolved :: struct {
	toolCallID: string,
	choice:     Approval_Choice,
}

Subagent_Started :: struct {
	parentToolCallID: string,
	task:             string,
}

Subagent_Finished :: struct {
	parentToolCallID: string,
	task:             string,
	result:           string,
	failed:           bool,
	// The stream error of a failed subagent, or "".
	errorText:        string,
}

Turn_End_Reason :: enum int {
	Completed = 0,
	Canceled,
	Failed,
}

Turn_Ended :: struct {
	reason:    Turn_End_Reason,
	errorText: string,
}

Notice_Severity :: enum int {
	Info = 0,
	Warning,
	Error,
}

// A short status message, for example "Tool call denied".
Notice :: struct {
	severity: Notice_Severity,
	text:     string,
}

Session_Event :: union {
	Message_Delta,
	Thinking_Changed,
	Usage_Updated,
	Tool_Call_Started,
	Tool_Call_Updated,
	Approval_Requested,
	Approval_Safety_Updated,
	Approval_Resolved,
	Subagent_Started,
	Subagent_Finished,
	Turn_Ended,
	Notice,
}

// Returns the next event of the session, and false when there is none. The caller owns the
// event and frees it with session_event_destroy, with the allocator of the session.
session_next_event :: proc(session: ^Session) -> (Session_Event, bool) {
	if session == nil || len(session.events) == 0 {
		return nil, false
	}
	event := session.events[0]
	ordered_remove(&session.events, 0)
	return event, true
}

session_event_destroy :: proc(event: ^Session_Event, allocator := context.allocator) {
	switch &value in event {
	case Message_Delta:
		delete(value.text, allocator)
		delete(value.parentToolCallID, allocator)
	case Thinking_Changed, Usage_Updated:
	case Tool_Call_Started:
		delete(value.toolCallID, allocator)
		delete(value.toolID, allocator)
		delete(value.target, allocator)
		delete(value.arguments, allocator)
	case Tool_Call_Updated:
		delete(value.toolCallID, allocator)
		delete(value.output, allocator)
	case Approval_Requested:
		delete(value.toolCallID, allocator)
		permission_action_copy_destroy(&value.action, allocator)
		delete(value.safety.response, allocator)
	case Approval_Safety_Updated:
		delete(value.toolCallID, allocator)
		delete(value.safety.response, allocator)
	case Approval_Resolved:
		delete(value.toolCallID, allocator)
	case Subagent_Started:
		delete(value.parentToolCallID, allocator)
		delete(value.task, allocator)
	case Subagent_Finished:
		delete(value.parentToolCallID, allocator)
		delete(value.task, allocator)
		delete(value.result, allocator)
		delete(value.errorText, allocator)
	case Turn_Ended:
		delete(value.errorText, allocator)
	case Notice:
		delete(value.text, allocator)
	}
	event^ = nil
}

// Copies every string of action. Free the copy with permission_action_copy_destroy.
permission_action_copy :: proc(
	action: tool_policy.Permission_Action,
	allocator := context.allocator,
) -> tool_policy.Permission_Action {
	return tool_policy.Permission_Action {
		effect = action.effect,
		projectRoot = strings.clone(action.projectRoot, allocator),
		targetPath = strings.clone(action.targetPath, allocator),
		targetPathOwned = true,
		command = strings.clone(action.command, allocator),
		workingDirectory = strings.clone(action.workingDirectory, allocator),
		workingDirectoryOwned = true,
	}
}

permission_action_copy_destroy :: proc(
	action: ^tool_policy.Permission_Action,
	allocator := context.allocator,
) {
	delete(action.projectRoot, allocator)
	delete(action.targetPath, allocator)
	delete(action.command, allocator)
	delete(action.workingDirectory, allocator)
	action^ = {}
}

// Copies the safety strings of safety. Free the copy by deleting its response.
approval_safety_copy :: proc(
	safety: Approval_Safety,
	allocator := context.allocator,
) -> Approval_Safety {
	return Approval_Safety {
		status = safety.status,
		verdict = safety.verdict,
		response = strings.clone(safety.response, allocator),
	}
}

session_emit :: proc(session: ^Session, event: Session_Event) {
	append(&session.events, event)
}

session_emit_notice :: proc(session: ^Session, text: string, severity := Notice_Severity.Info) {
	session_emit(
		session,
		Notice{severity = severity, text = strings.clone(text, session.allocator)},
	)
}

session_emit_tool_call_started :: proc(
	session: ^Session,
	toolCallID, toolID, target, arguments: string,
) {
	allocator := session.allocator
	session_emit(
		session,
		Tool_Call_Started {
			toolCallID = strings.clone(toolCallID, allocator),
			toolID = strings.clone(toolID, allocator),
			target = strings.clone(target, allocator),
			arguments = strings.clone(arguments, allocator),
		},
	)
}

session_emit_tool_call_updated :: proc(
	session: ^Session,
	toolCallID: string,
	status: Tool_Call_Status,
	output := "",
) {
	allocator := session.allocator
	session_emit(
		session,
		Tool_Call_Updated {
			toolCallID = strings.clone(toolCallID, allocator),
			status = status,
			output = strings.clone(output, allocator),
		},
	)
}

session_events_destroy :: proc(events: ^[dynamic]Session_Event, allocator: mem.Allocator) {
	for &event in events {
		session_event_destroy(&event, allocator)
	}
	delete(events^)
}
