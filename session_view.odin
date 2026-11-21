package main

import "core:fmt"
import "core:strings"
import "core:time"
import "session"
import "text_input"
import "tool_policy"

// The terminal UI is the event sink of its session: it drains session events and turns them
// into history lines, status text and the approval overlay. All formatting of agent output is
// here; the session package only reports data (ADR-0002).

SPINNER_FRAMES :: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
SPINNER_FRAME_INTERVAL :: 100 * time.Millisecond
APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES :: 200

// The spinner of the pending assistant entry.
Assistant_Spinner :: struct {
	visible:    bool,
	frameIndex: int,
	lastFrame:  time.Tick,
}

// The history line of a tool call, found by the tool call ID of the model.
Tool_History_Line :: struct {
	toolCallID:   string,
	historyIndex: int,
	toolID:       string,
	target:       string,
}

// Approval_View is the view state of the approval overlay, from the Approval_Requested and
// Approval_Safety_Updated events. The decision state stays in the session.
Approval_View :: struct {
	active:     bool,
	toolCallID: string,
	action:     tool_policy.Permission_Action,
	safety:     session.Approval_Safety,
	choice:     session.Approval_Choice,
}

// Advances the session and shows its events. It returns true when the screen needs a redraw.
app_poll_session :: proc(state: ^App_State) -> bool {
	dirty := session.session_poll(state.session)
	dirty = app_drain_session_events(state) || dirty
	dirty = app_update_assistant_spinner(state) || dirty
	return dirty
}

// Shows all pending session events. It returns true when it showed at least one.
app_drain_session_events :: proc(state: ^App_State) -> bool {
	if state.session == nil {
		return false
	}
	drained := false
	fullRedraw := false
	for {
		event, eventOK := session.session_next_event(state.session)
		if !eventOK {
			break
		}
		drained = true
		if _, isDelta := event.(session.Message_Delta); !isDelta {
			fullRedraw = true
		}
		app_show_session_event(state, event)
		session.session_event_destroy(&event, state.session.allocator)
	}
	if fullRedraw {
		// Streamed text alone redraws only the history panel. Other events can change the
		// status bar or the overlays too.
		state.historyRenderOnly = false
	}
	return drained
}

// Shows one session event in the history panel, the status text or the approval overlay.
app_show_session_event :: proc(state: ^App_State, event: session.Session_Event) {
	switch value in event {
	case session.Notice:
		app_set_status_copy(state, value.text)
	case session.Message_Delta:
		app_show_message_delta(state, value)
	case session.Thinking_Changed:
		if value.thinking {
			if !app_assistant_entry_valid(state) {
				append_history(state, app_agent_message_role(value.subagentDepth), "")
				state.assistantHistoryIndex = len(state.history) - 1
			}
			state.status = "Assistant thinking"
		}
	case session.Usage_Updated:
		state.usage = value.usage
		state.contextWindowTokens = value.contextWindowTokens
	case session.Tool_Call_Started:
		state.assistantHistoryIndex = -1
		append_history(state, .Tool, app_tool_history_line(value.toolID, value.target, ""))
		append(
			&state.toolHistory,
			Tool_History_Line {
				toolCallID = strings.clone(value.toolCallID, context.allocator),
				historyIndex = len(state.history) - 1,
				toolID = strings.clone(value.toolID, context.allocator),
				target = strings.clone(value.target, context.allocator),
			},
		)
	case session.Tool_Call_Updated:
		app_update_tool_call_line(state, value.toolCallID, app_tool_status_text(value.status))
	case session.Approval_Requested:
		app_show_approval_request(state, value)
	case session.Approval_Safety_Updated:
		view := &state.approvalView
		if view.active && view.toolCallID == value.toolCallID {
			delete(view.safety.response, context.allocator)
			view.safety = session.approval_safety_copy(value.safety, context.allocator)
		}
	case session.Approval_Resolved:
		if state.approvalView.toolCallID == value.toolCallID {
			app_clear_approval_view(state)
		}
		app_pop_overlay_if(state, Approval_Overlay)
	case session.Subagent_Started:
		app_update_tool_call_line(state, value.parentToolCallID, "delegated")
		state.assistantHistoryIndex = -1
		append_history(state, .Subagent, fmt.tprintf("Subagent started: %s", value.task))
		state.status = "Subagent running"
	case session.Subagent_Finished:
		if value.failed && value.errorText != "" {
			append_history(state, .Assistant, value.errorText)
		}
		state.assistantHistoryIndex = -1
		if value.failed {
			append_history(
				state,
				.Subagent,
				fmt.tprintf("Subagent failed (%s): %s", value.task, value.result),
			)
		} else {
			append_history(
				state,
				.Subagent,
				fmt.tprintf("Subagent completed (%s): %s", value.task, value.result),
			)
		}
		state.status = "Subagent finished"
	case session.Turn_Ended:
		switch value.reason {
		case .Completed:
			state.status = "Assistant response complete"
		case .Failed:
			append_history(state, .Assistant, value.errorText)
			state.status = "Assistant stream failed"
		case .Canceled:
			state.status = "Assistant stream canceled"
		}
		state.assistantHistoryIndex = -1
	}
}

// Sets the status text to a copy of text, for text that the caller frees.
app_set_status_copy :: proc(state: ^App_State, text: string) {
	previous := state.statusText
	state.statusText = strings.clone(text, context.allocator)
	state.status = state.statusText
	delete(previous, context.allocator)
}

app_agent_message_role :: proc(subagentDepth: int) -> History_Role {
	if subagentDepth > 0 {
		return .Subagent
	}
	return .Assistant
}

app_assistant_entry_valid :: proc(state: ^App_State) -> bool {
	return state.assistantHistoryIndex >= 0 && state.assistantHistoryIndex < len(state.history)
}

app_show_message_delta :: proc(state: ^App_State, delta: session.Message_Delta) {
	if !app_assistant_entry_valid(state) {
		append_history(state, app_agent_message_role(delta.subagentDepth), delta.text)
		state.assistantHistoryIndex = len(state.history) - 1
	} else {
		entry := &state.history[state.assistantHistoryIndex]
		updated := strings.concatenate({entry.content, delta.text}, context.allocator)
		delete(entry.content)
		entry.content = updated
		entry.cachedLineWidth = 0
		entry.cachedLineCount = 0
	}
	state.historyRenderOnly = true
}

// Returns the newest history line of the tool call toolCallID. Tool call IDs can repeat in
// one conversation, so the newest line wins.
app_find_tool_history_line :: proc(state: ^App_State, toolCallID: string) -> ^Tool_History_Line {
	for index := len(state.toolHistory) - 1; index >= 0; index -= 1 {
		if state.toolHistory[index].toolCallID == toolCallID {
			return &state.toolHistory[index]
		}
	}
	return nil
}

app_update_tool_call_line :: proc(state: ^App_State, toolCallID: string, status: string) {
	line := app_find_tool_history_line(state, toolCallID)
	if line == nil || line.historyIndex < 0 || line.historyIndex >= len(state.history) {
		return
	}
	entry := &state.history[line.historyIndex]
	if entry.content != "" {
		delete(entry.content, context.allocator)
	}
	entry.content = strings.clone(
		app_tool_history_line(line.toolID, line.target, status),
		context.allocator,
	)
	entry.cachedLineWidth = 0
	entry.cachedLineCount = 0
	state.historyScrollOffset = 0
	state.historySelection = {}
}

app_clear_tool_history :: proc(state: ^App_State) {
	for &line in state.toolHistory {
		delete(line.toolCallID, context.allocator)
		delete(line.toolID, context.allocator)
		delete(line.target, context.allocator)
	}
	clear(&state.toolHistory)
}

app_tool_status_text :: proc(status: session.Tool_Call_Status) -> string {
	switch status {
	case .Awaiting_Approval:
		return "awaiting approval"
	case .Running:
		return "running"
	case .Completed:
		return "completed"
	case .Failed:
		return "failed"
	case .Denied:
		return "denied"
	}
	return "unknown"
}

app_tool_history_content :: proc(call: tool_policy.Tool_Call, status: string) -> string {
	return app_tool_history_line(call.id, session.tool_call_target(call), status)
}

app_tool_history_line :: proc(toolID: string, target: string, status: string) -> string {
	if target == "" {
		return fmt.tprintf("%s (%s)", toolID, status)
	}
	displayTarget := approval_display_text(target, context.temp_allocator)
	return fmt.tprintf("%s: %s (%s)", toolID, displayTarget, status)
}

// Shows the approval overlay for an Approval_Requested event.
app_show_approval_request :: proc(state: ^App_State, request: session.Approval_Requested) {
	app_clear_approval_view(state)
	state.approvalView = Approval_View {
		active     = true,
		toolCallID = strings.clone(request.toolCallID, context.allocator),
		action     = session.permission_action_copy(request.action, context.allocator),
		safety     = session.approval_safety_copy(request.safety, context.allocator),
		choice     = .Allow_Once,
	}
	for overlay in state.overlayStack {
		if _, isApproval := overlay.(Approval_Overlay); isApproval {
			state.status = "Permission approval required"
			return
		}
	}
	app_push_overlay(state, Approval_Overlay{})
	state.status = "Permission approval required"
}

app_clear_approval_view :: proc(state: ^App_State) {
	view := &state.approvalView
	delete(view.toolCallID, context.allocator)
	if view.active {
		session.permission_action_copy_destroy(&view.action, context.allocator)
	}
	delete(view.safety.response, context.allocator)
	view^ = {}
}

// Reports whether the approval overlay shows a pending approval.
app_approval_pending :: proc(state: ^App_State) -> bool {
	return state.approvalView.active
}

// Reports whether the safety classifier of the shown approval does not run.
app_approval_safety_ready :: proc(state: ^App_State) -> bool {
	return state.approvalView.safety.status != .Checking
}

// Answers the shown approval with choice and shows the result. Overlay keys and the headless
// harness use it.
app_apply_approval_choice :: proc(state: ^App_State, choice: session.Approval_Choice) {
	if !app_approval_pending(state) {
		app_pop_overlay_if(state, Approval_Overlay)
		return
	}
	_ = session.session_resolve_approval(state.session, state.approvalView.toolCallID, choice)
	_ = app_drain_session_events(state)
}

// Cancels the active agent of the session (/stop).
app_cancel_session :: proc(state: ^App_State) {
	_ = session.session_cancel(state.session)
	_ = app_drain_session_events(state)
}

app_update_assistant_spinner :: proc(state: ^App_State) -> bool {
	entryValid := app_assistant_entry_valid(state)
	shouldSpin :=
		session.session_turn_active(state.session) &&
		entryValid &&
		state.history[state.assistantHistoryIndex].content == ""
	spinnerDirty := app_update_spinner(&state.spinner, shouldSpin)
	if spinnerDirty && entryValid {
		entry := &state.history[state.assistantHistoryIndex]
		entry.cachedLineWidth = 0
		entry.cachedLineCount = 0
		state.historyRenderOnly = true
	}
	return spinnerDirty
}

app_update_spinner :: proc(spinner: ^Assistant_Spinner, shouldSpin: bool) -> bool {
	if !shouldSpin {
		if !spinner.visible {
			return false
		}
		spinner^ = {}
		return true
	}
	if !spinner.visible {
		spinner.visible = true
		spinner.frameIndex = 0
		spinner.lastFrame = time.tick_now()
		return true
	}
	if time.tick_since(spinner.lastFrame) < SPINNER_FRAME_INTERVAL {
		return false
	}
	spinner.frameIndex = (spinner.frameIndex + 1) % len(SPINNER_FRAMES)
	spinner.lastFrame = time.tick_now()
	return true
}

app_assistant_spinner_frame :: proc(state: ^App_State) -> string {
	if !state.spinner.visible {
		return ""
	}
	frames := SPINNER_FRAMES
	return frames[state.spinner.frameIndex]
}

app_context_usage_status_text :: proc(
	state: ^App_State,
	allocator := context.temp_allocator,
) -> string {
	if state == nil {
		return ""
	}
	usage := state.usage
	contextWindowTokens := state.contextWindowTokens
	active := session.session_turn_active(state.session)
	if !usage.hasInputTokens {
		if active {
			return "ctx ..."
		}
		return ""
	}

	inputText := assistant_stream_compact_token_count(usage.inputTokens, allocator)
	if contextWindowTokens <= 0 {
		return fmt.tprintf("ctx %s", inputText)
	}
	contextText := assistant_stream_compact_token_count(contextWindowTokens, allocator)
	percentage := usage.inputTokens * 100 / contextWindowTokens
	return fmt.tprintf("ctx %s/%s %d%%", inputText, contextText, percentage)
}

assistant_stream_compact_token_count :: proc(
	tokens: int,
	allocator := context.temp_allocator,
) -> string {
	if tokens < 1000 {
		return fmt.tprintf("%d", tokens)
	}
	tenths := (tokens + 50) / 100
	whole := tenths / 10
	decimal := tenths % 10
	if decimal == 0 {
		return fmt.tprintf("%dk", whole)
	}
	return fmt.tprintf("%d.%dk", whole, decimal)
}

approval_safety_display_text :: proc(
	response: string,
	allocator := context.temp_allocator,
) -> string {
	text := response
	lineEnd := strings.index_byte(text, '\n')
	if lineEnd >= 0 {
		text = text[:lineEnd]
	}
	text = strings.trim_space(text)
	if text_input.unicode_grapheme_count(text) <= APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES {
		return strings.clone(text, allocator)
	}
	end := text_input.unicode_grapheme_to_byte_offset(
		text,
		APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES - len("..."),
	)
	return strings.concatenate({text[:end], "..."}, allocator)
}

// Returns the safety advice of the shown approval for display.
app_approval_safety_advice :: proc(
	state: ^App_State,
	allocator := context.temp_allocator,
) -> string {
	return approval_safety_display_text(state.approvalView.safety.response, allocator)
}
