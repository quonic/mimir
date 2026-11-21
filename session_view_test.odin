package main

import "agent"
import "core:testing"
import "session"
import "tool_policy"

// Tests of the terminal UI as the sink of session events: history lines, status text, the
// spinner and the approval overlay.

@(test)
test_session_view_formats_tool_call_lines :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	app_show_session_event(
		&state,
		session.Tool_Call_Started {
			toolCallID = "call-1",
			toolID = "read_file",
			target = "notes.md",
			arguments = `{"file_path":"notes.md"}`,
		},
	)
	app_show_session_event(
		&state,
		session.Tool_Call_Updated{toolCallID = "call-1", status = .Running},
	)
	historyIndex := len(state.history) - 1
	assert(
		state.history[historyIndex].content == "read_file: notes.md (running)",
		"expected a running tool line",
	)
	app_show_session_event(
		&state,
		session.Tool_Call_Updated{toolCallID = "call-1", status = .Completed, output = "text"},
	)
	assert(len(state.history) - 1 == historyIndex, "expected the same tool line")
	assert(
		state.history[historyIndex].content == "read_file: notes.md (completed)",
		"expected a completed tool line",
	)
	app_show_session_event(&state, session.Notice{text = "Tool call completed"})
	assert(state.status == "Tool call completed", "expected the notice in the status text")
	assert(len(state.history) - 1 == historyIndex, "expected no history line for a notice")
	_ = t
}

@(test)
test_session_view_streams_text_into_one_entry_and_ends_turn :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	app_show_session_event(&state, session.Message_Delta{text = "first "})
	app_show_session_event(&state, session.Message_Delta{text = "response"})
	app_show_session_event(&state, session.Turn_Ended{reason = .Completed})
	entry := state.history[len(state.history) - 1]
	assert(entry.role == .Assistant, "expected an assistant entry")
	assert(entry.content == "first response", "expected the streamed text in one entry")
	assert(state.status == "Assistant response complete", "expected the completion status")
	assert(state.assistantHistoryIndex == -1, "expected the turn end to close the entry")

	app_show_session_event(&state, session.Turn_Ended{reason = .Failed, errorText = "Boom"})
	assert(state.history[len(state.history) - 1].content == "Boom", "expected the error text")
	assert(state.status == "Assistant stream failed", "expected the failure status")
	_ = t
}

@(test)
test_session_view_shows_subagent_lines :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	app_show_session_event(
		&state,
		session.Tool_Call_Started {
			toolCallID = "call-1",
			toolID = "run_subagent",
			target = "delegate",
		},
	)
	app_show_session_event(
		&state,
		session.Tool_Call_Updated{toolCallID = "call-1", status = .Running},
	)
	toolIndex := len(state.history) - 1
	app_show_session_event(
		&state,
		session.Subagent_Started{parentToolCallID = "call-1", task = "delegate"},
	)
	assert(
		state.history[toolIndex].content == "run_subagent: delegate (delegated)",
		"expected the run_subagent line to show the delegation",
	)
	assert(
		state.history[len(state.history) - 1].content == "Subagent started: delegate",
		"expected a subagent start line",
	)
	app_show_session_event(
		&state,
		session.Message_Delta{text = "child text", subagentDepth = 1},
	)
	assert(
		state.history[len(state.history) - 1].role == .Subagent,
		"expected subagent text in a subagent entry",
	)
	app_show_session_event(
		&state,
		session.Subagent_Finished {
			parentToolCallID = "call-1",
			task = "delegate",
			result = "child answer",
		},
	)
	assert(
		state.history[len(state.history) - 1].content ==
		"Subagent completed (delegate): child answer",
		"expected a subagent completion line",
	)
	assert(state.status == "Subagent finished", "expected the subagent status")
	_ = t
}

@(test)
test_session_view_opens_and_closes_approval_overlay :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	app_show_session_event(
		&state,
		session.Approval_Requested {
			toolCallID = "call-1",
			action = tool_policy.Permission_Action{effect = .Execute, command = "pwd"},
			safety = session.Approval_Safety{status = .Checking},
		},
	)
	assert(app_has_overlay(&state, Approval_Overlay), "expected the approval overlay")
	assert(state.status == "Permission approval required", "expected the approval status")
	assert(!app_approval_safety_ready(&state), "expected the classifier to block choices")
	assert(!app_handle_approval_input(&state, '4'), "expected choices to wait for the verdict")

	app_show_session_event(
		&state,
		session.Approval_Safety_Updated {
			toolCallID = "call-1",
			safety = session.Approval_Safety {
				status = .Checked,
				verdict = .Risky,
				response = "RISKY|Could do anything.",
			},
		},
	)
	assert(app_approval_safety_ready(&state), "expected the verdict to unlock choices")
	sequence := render_app_frame_sequence(&state, 24, 80, context.temp_allocator)
	assert(contains_string(sequence, "RISKY|Could do anything."), "expected the safety advice")

	app_show_session_event(
		&state,
		session.Approval_Resolved{toolCallID = "call-1", choice = .Deny},
	)
	assert(!app_has_overlay(&state, Approval_Overlay), "expected the overlay to close")
	assert(!app_approval_pending(&state), "expected no shown approval")
	_ = t
}

@(test)
test_session_view_shows_spinner_while_provider_is_processing :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assert(
		session.agent_host_start_active(&state.session.host, agent.Agent_Start_Options{}) ==
		.None,
		"expected active agent to start",
	)
	// Mirrors the placeholder entry that app_submit_input appends when a turn starts.
	append_history(&state, .Assistant, "")
	state.assistantHistoryIndex = len(state.history) - 1

	assert(app_poll_session(&state), "expected the spinner to appear before any text")
	assert(state.spinner.visible, "expected a visible spinner while the provider works")
	assert(
		app_assistant_spinner_frame(&state) == SPINNER_FRAMES[0],
		"expected the first spinner frame",
	)
	_ = t
}
