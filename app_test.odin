package main

import "ai"
import "console"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_input_buffer_tracks_multiline_text :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "first\nsecond")
	assert(input_buffer_line_count(&buffer) == 2, "expected newline to expand input lines")
	assert(
		input_buffer_string(&buffer) == "first\nsecond",
		"expected input buffer to preserve pasted text",
	)

	assert(input_buffer_backspace(&buffer), "expected backspace to remove trailing byte")
	assert(input_buffer_string(&buffer) == "first\nsecon", "expected backspace to update text")
	assert(
		input_buffer_cursor_position(&buffer) == len(input_buffer_string(&buffer)),
		"expected cursor to remain at end after trailing backspace",
	)

	submitted := input_buffer_submit(&buffer, context.temp_allocator)
	assert(submitted == "first\nsecon", "expected submitted text to match input")
	assert(input_buffer_string(&buffer) == "", "expected submit to clear input")
	assert(input_buffer_cursor_position(&buffer) == 0, "expected submit to reset cursor")
	_ = t
}

@(test)
test_input_buffer_replaces_and_deletes_grapheme_selection :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "aébc")
	input_buffer_extend_selection_to(&buffer, 1)
	assert(input_buffer_has_selection(&buffer), "expected selection after extending from end")
	assert(input_buffer_selection_text(&buffer) == "ébc", "expected selected UTF-8 graphemes")

	input_buffer_push_text(&buffer, "X")
	assert(input_buffer_string(&buffer) == "aX", "expected inserted text to replace selection")
	assert(!input_buffer_has_selection(&buffer), "expected replacement to clear selection")

	input_buffer_select_all(&buffer)
	assert(input_buffer_backspace(&buffer), "expected backspace to delete the selection")
	assert(input_buffer_string(&buffer) == "", "expected selection deletion to clear text")
	assert(
		input_buffer_cursor_position(&buffer) == 0,
		"expected selection deletion to place cursor at start",
	)
	_ = t
}

@(test)
test_approval_modal_navigates_and_escape_denies :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(&state, Tool_Call{id = "write_file", filePath = "generated/output.txt"}),
		"expected write call to open approval modal",
	)
	assert(state.mode == .Approval, "expected approval mode")
	assert(state.approval.choice == .Allow_Once, "expected once approval selected initially")
	assert(app_handle_approval_input(&state, 'j'), "expected approval choice movement")
	assert(state.approval.choice == .Allow_Session, "expected session approval selected")
	assert(!app_handle_approval_input(&state, 0x1b), "expected escape sequence start")
	assert(app_handle_approval_input(&state, 'x'), "expected escape to deny approval")
	assert(state.mode == .Chat, "expected denial to restore chat mode")
	assert(state.status == "Tool call denied", "expected escape denial status")
	_ = t
}

@(test)
test_approval_display_text_escapes_terminal_controls :: proc(t: ^testing.T) {
	display := approval_display_text("printf 'one\ntwo'\x1b[2J\t", context.temp_allocator)
	assert(
		display == "printf 'one\\ntwo'\\e[2J\\t",
		"expected terminal controls to be escaped for approval display",
	)
	_ = t
}

@(test)
test_approval_modal_keeps_command_text_after_source_call_is_destroyed :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	call, callOK := app_tool_call_from_ai(
		ai.Tool_Call {
			id = "call-1",
			name = "run_command",
			arguments = `{"command":"echo \"Test Shell command\"","shell":"/bin/bash"}`,
		},
		context.allocator,
	)
	assert(callOK, "expected command tool call to decode")
	assert(app_show_approval(&state, call), "expected command call to open approval modal")
	tool_call_destroy(&call, context.allocator)

	sequence := render_app_frame_sequence(&state, 18, 80, context.temp_allocator)
	assert(
		contains_string(sequence, `echo "Test Shell command"`),
		"expected approval modal to display retained command text",
	)
	_ = t
}

@(test)
test_approval_safety_prompt_uses_only_command_details :: proc(t: ^testing.T) {
	prompt := approval_safety_prompt("git status", "/workspace/project")
	assert(strings.contains(prompt, "git status"), "expected command in safety prompt")
	assert(
		strings.contains(prompt, "/workspace/project"),
		"expected working directory in safety prompt",
	)
	assert(
		!strings.contains(prompt, "prior conversation"),
		"expected prompt to exclude prior conversation",
	)
	_ = t
}

@(test)
test_approval_safety_blocks_input_until_analysis_completes :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(&state, Tool_Call{id = "write_file", filePath = "generated/output.txt"}),
		"expected write call to open approval modal",
	)
	state.approval.safety.active = true
	assert(
		!app_handle_approval_input(&state, '4'),
		"expected pending safety analysis to ignore choice",
	)
	assert(
		!app_handle_approval_input(&state, '\r'),
		"expected pending safety analysis to ignore approval",
	)
	assert(state.mode == .Approval, "expected pending analysis to keep modal open")
	assert(state.approval.choice == .Allow_Once, "expected pending analysis to preserve selection")

	state.approval.safety.active = false
	state.approval.safety.unavailable = true
	assert(app_handle_approval_input(&state, '4'), "expected unavailable advice to unlock choices")
	assert(app_handle_approval_input(&state, '\r'), "expected unavailable advice to allow denial")
	assert(state.mode == .Chat, "expected denial after unavailable advice to close modal")
	_ = t
}

@(test)
test_approval_modal_renders_unavailable_safety_advice :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(&state, Tool_Call{id = "run_command", command = "git status"}),
		"expected command call to open approval modal",
	)
	state.approval.safety.active = false
	state.approval.safety.unavailable = true
	sequence := render_app_frame_sequence(&state, 24, 80, context.temp_allocator)
	assert(
		contains_string(sequence, "Safety advice: unavailable"),
		"expected unavailable safety advice in command approval modal",
	)
	_ = t
}

@(test)
test_app_tool_definitions_include_ollama :: proc(t: ^testing.T) {
	ollamaTools := app_tool_definitions_for_provider(.Ollama, context.allocator)
	defer delete(ollamaTools)
	assert(len(ollamaTools) == 7, "expected Ollama to receive all built-in tools")

	openAITools := app_tool_definitions_for_provider(.OpenAI, context.allocator)
	defer delete(openAITools)
	assert(len(openAITools) == 7, "expected OpenAI to receive all built-in tools")
	_ = t
}

@(test)
test_app_embedding_client_requires_embedding_configuration :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	_, clientError := app_embedding_client(&state)
	assert(
		clientError == .Invalid_Request,
		"expected missing embedding selection to reject client",
	)
	_ = t
}

@(test)
test_app_embedding_client_rejects_disabled_embedding_provider :: proc(t: ^testing.T) {
	state: App_State
	state.config.embeddingProvider = "embeddings"
	state.config.embeddingModel = "nomic-embed-text"
	state.config.providers = make([dynamic]Provider_Config, 0, 1, context.temp_allocator)
	defer delete(state.config.providers)
	append(
		&state.config.providers,
		Provider_Config {
			name = "embeddings",
			type = .Ollama,
			endpoint = "http://localhost:11434",
			enabled = false,
		},
	)

	_, clientError := app_embedding_client(&state)
	assert(clientError == .Interface_Not_Found, "expected disabled embedding provider rejection")
	_ = t
}

@(test)
test_app_queues_streamed_tool_call_for_approval :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("run_command", context.allocator),
			arguments = strings.clone(`{"command":"pwd","shell":"/bin/sh"}`, context.allocator),
		},
	)

	assert(app_process_pending_stream_tool_calls(&state), "expected queued tool call to process")
	assert(state.mode == .Approval, "expected execute tool call to require approval")
	assert(len(state.stream.toolCalls) == 0, "expected queued tool call to be consumed")
	assert(
		state.history[len(state.history) - 1].content == "run_command (awaiting approval)",
		"expected approval-pending tool history entry",
	)
	_ = t
}

@(test)
test_app_approved_tool_history_runs_and_completes :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.mode = .Config
	append(
		&state.stream.conversation,
		ai.Message {
			role = .Assistant,
			content = strings.clone("Checking directory", context.allocator),
		},
	)
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("run_command", context.allocator),
			arguments = strings.clone(`{"command":"pwd"}`, context.allocator),
		},
	)

	assert(app_process_pending_stream_tool_calls(&state), "expected tool call to await approval")
	historyIndex := len(state.history) - 1
	assert(
		state.history[historyIndex].content == "run_command (awaiting approval)",
		"expected awaiting approval history entry",
	)
	app_apply_approval_choice(&state, .Allow_Once)
	assert(state.mode == .Chat, "expected approval to return to chat mode")
	assert(
		state.history[historyIndex].content == "run_command (running)",
		"expected approved tool to enter running history state",
	)
	state.mode = .Config
	for !app_poll_tool_execution(&state) {
	}
	assert(
		state.history[historyIndex].content == "run_command (completed)",
		"expected approved tool to complete in history",
	)
	_ = t
}

@(test)
test_app_denied_tool_history_is_labeled :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	append(
		&state.stream.conversation,
		ai.Message {
			role = .Assistant,
			content = strings.clone("Writing a file", context.allocator),
		},
	)
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("write_file", context.allocator),
			arguments = strings.clone(
				`{"file_path":"generated/output.txt","content":"test","overwrite":"false"}`,
				context.allocator,
			),
		},
	)

	assert(app_process_pending_stream_tool_calls(&state), "expected tool call to await approval")
	historyIndex := len(state.history) - 1
	app_apply_approval_choice(&state, .Deny)
	assert(
		state.history[historyIndex].content == "write_file (denied)",
		"expected denied tool history entry",
	)
	assert(len(state.stream.conversation) == 2, "expected denied result in continuation")
	assert(
		state.stream.conversation[1].toolResults[0].isError,
		"expected denied tool result to be an error",
	)
	_ = t
}

@(test)
test_app_decodes_ai_tool_call_arguments :: proc(t: ^testing.T) {
	aiCall := ai.Tool_Call {
		id        = "call-1",
		name      = "write_file",
		arguments = `{"file_path":"notes.txt","content":"hello","overwrite":"true"}`,
	}
	call, ok := app_tool_call_from_ai(aiCall, context.allocator)
	defer tool_call_destroy(&call, context.allocator)
	assert(ok, "expected JSON arguments to decode")
	assert(call.id == "write_file", "expected decoded tool ID")
	assert(call.filePath == "notes.txt", "expected decoded file path")
	assert(call.content == "hello", "expected decoded content")
	_ = t
}

@(test)
test_app_decodes_search_code_tool_arguments :: proc(t: ^testing.T) {
	aiCall := ai.Tool_Call {
		id        = "call-search",
		name      = "search_code",
		arguments = `{"query":"permission dispatch","max_results":50}`,
	}
	call, ok := app_tool_call_from_ai(aiCall, context.allocator)
	defer tool_call_destroy(&call, context.allocator)
	assert(ok, "expected search_code arguments to decode")
	assert(call.query == "permission dispatch", "expected search query")
	assert(call.maxResults == SEARCH_CODE_MAX_RESULTS, "expected maximum results cap")
	_ = t
}

@(test)
test_app_search_code_results_json_serializes_references :: proc(t: ^testing.T) {
	results := [1]Code_Search_Result {
		{id = "src/main.odin:10-20", metadata = "src/main.odin:10-20"},
	}
	index := Code_Index {
		projectRoot = "/project",
	}
	output := app_search_code_results_json(&index, results[:], context.temp_allocator)
	defer delete(output, context.temp_allocator)
	assert(
		output ==
		`{"results":[{"path":"src/main.odin","start_line":10,"end_line":20,"excerpt":""}]}`,
		"expected JSON source locations",
	)
	_ = t
}

@(test)
test_app_retains_tool_result_for_continuation :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	append(
		&state.stream.conversation,
		ai.Message{role = .Assistant, content = strings.clone("Calling tool", context.allocator)},
	)

	app_append_tool_result(&state, "call-1", "package main", false)
	assert(len(state.stream.conversation) == 2, "expected tool result conversation entry")
	resultMessage := state.stream.conversation[1]
	assert(resultMessage.role == .Tool, "expected tool result message role")
	assert(len(resultMessage.toolResults) == 1, "expected one typed tool result")
	assert(resultMessage.toolResults[0].toolCallID == "call-1", "expected call ID")
	assert(resultMessage.toolResults[0].content == "package main", "expected tool output")
	_ = t
}

@(test)
test_app_releases_retained_failed_command_output :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	append(&state.stream.conversation, ai.Message{role = .Assistant})

	output := run_command_tool_proc("ip add")
	app_append_tool_result(&state, "call-1", output, true)
	delete(output, context.allocator)

	app_clear_assistant_stream_conversation(&state.stream)
	assert(len(state.stream.conversation) == 0, "expected retained command output to clear")
	_ = t
}

@(test)
test_app_shows_running_and_completed_tool_history :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.mode = .Config
	append(
		&state.stream.conversation,
		ai.Message {
			role = .Assistant,
			content = strings.clone("Reading app.odin", context.allocator),
		},
	)
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("read_file", context.allocator),
			arguments = strings.clone(`{"file_path":"app.odin"}`, context.allocator),
		},
	)

	assert(
		app_process_pending_stream_tool_calls(&state),
		"expected read-only tool call to process",
	)
	assert(len(state.history) == 2, "expected tool call to appear in history")
	assert(
		state.history[1].content == "read_file (running)",
		"expected running tool history entry",
	)
	for !app_poll_tool_execution(&state) {
	}
	assert(
		state.history[1].content == "read_file (completed)",
		"expected completed tool history entry",
	)
	assert(len(state.stream.conversation) == 2, "expected tool result to remain in continuation")
	result := state.stream.conversation[1].toolResults[0]
	assert(result.content != "", "expected retained tool output")
	assert(!result.isError, "expected successful tool result")
	_ = t
}

@(test)
test_app_shows_failed_tool_history :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.mode = .Config
	append(
		&state.stream.conversation,
		ai.Message {
			role = .Assistant,
			content = strings.clone("Reading a file", context.allocator),
		},
	)
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("read_file", context.allocator),
			arguments = strings.clone(`{"file_path":"missing.odin"}`, context.allocator),
		},
	)

	assert(
		app_process_pending_stream_tool_calls(&state),
		"expected read-only tool call to process",
	)
	assert(len(state.history) == 2, "expected tool error to appear in history")
	for !app_poll_tool_execution(&state) {
	}
	assert(state.history[1].role == .Tool, "expected visible tool failure entry")
	assert(state.history[1].content == "read_file (failed)", "expected failed tool history entry")
	result := state.stream.conversation[1].toolResults[0]
	assert(result.isError, "expected failed tool result")
	_ = t
}

@(test)
test_app_stream_conversation_uses_app_allocator :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	history := []History_Entry{{role = .User, content = "Read main.odin"}}

	state.stream.conversation = app_build_ai_messages(history, state.stream.bufferAllocator)
	app_append_tool_result(&state, "call-1", "package main", false)

	assert(len(state.stream.conversation) == 2, "expected retained tool conversation")
	app_clear_assistant_stream_conversation(&state.stream)
	assert(len(state.stream.conversation) == 0, "expected cleared retained tool conversation")
	_ = t
}

@(test)
test_tool_call_queue_reinitializes_with_stream_allocator :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	app_clear_assistant_stream_tool_calls(&state.stream)
	assert(len(state.stream.toolCalls) == 0, "expected empty reinitialized tool-call queue")
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("list_directory", context.allocator),
			arguments = strings.clone(`{"directory_path":"."}`, context.allocator),
		},
	)
	app_clear_assistant_stream_tool_calls(&state.stream)
	assert(len(state.stream.toolCalls) == 0, "expected tool-call queue cleanup")
	_ = t
}

@(test)
test_app_records_streamed_tool_turn_for_continuation :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	assistant_stream_append_partial(&state.stream, "I will inspect the file.")
	append(
		&state.stream.toolCalls,
		ai.Tool_Call {
			id = strings.clone("call-1", context.allocator),
			name = strings.clone("read_file", context.allocator),
			arguments = strings.clone(`{"file_path":"main.odin"}`, context.allocator),
		},
	)

	assert(app_record_stream_tool_turn(&state), "expected streamed tool turn to record")
	assert(len(state.stream.conversation) == 1, "expected assistant conversation entry")
	message := state.stream.conversation[0]
	assert(message.role == .Assistant, "expected assistant tool-call message")
	assert(message.content == "I will inspect the file.", "expected streamed assistant text")
	assert(len(message.toolCalls) == 1, "expected retained tool call")
	assert(message.toolCalls[0].id == "call-1", "expected retained tool call ID")
	_ = t
}

@(test)
test_app_initializes_permission_dispatcher :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(state.dispatcherReady, "expected app to initialize permission dispatcher")
	assert(
		state.dispatcher.projectRoot == state.workingDirectory,
		"expected dispatcher to use the app working directory",
	)
	_ = t
}

@(test)
test_input_buffer_inserts_and_backspaces_at_cursor :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "ab")
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move left")
	input_buffer_push_byte(&buffer, 'X')

	assert(input_buffer_string(&buffer) == "aXb", "expected insertion at cursor")
	assert(input_buffer_cursor_position(&buffer) == 2, "expected cursor after inserted byte")
	assert(input_buffer_backspace(&buffer), "expected backspace before cursor")
	assert(input_buffer_string(&buffer) == "ab", "expected backspace to remove inserted byte")
	assert(
		input_buffer_cursor_position(&buffer) == 1,
		"expected cursor to move left after backspace",
	)
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move to start")
	assert(!input_buffer_move_cursor_left(&buffer), "expected left movement to stop at start")
	assert(!input_buffer_backspace(&buffer), "expected backspace at start to do nothing")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move right")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move to end")
	assert(!input_buffer_move_cursor_right(&buffer), "expected right movement to stop at end")
	_ = t
}

@(test)
test_input_buffer_moves_to_start_and_deletes_at_cursor :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "aéx")
	input_buffer_move_cursor_start(&buffer)
	assert(input_buffer_cursor_position(&buffer) == 0, "expected cursor at input start")
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove first grapheme")
	assert(
		input_buffer_string(&buffer) == "éx",
		"expected delete to preserve multi-byte grapheme",
	)
	assert(input_buffer_cursor_position(&buffer) == 0, "expected delete to retain cursor position")
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove multi-byte grapheme")
	assert(input_buffer_string(&buffer) == "x", "expected complete multi-byte grapheme removal")

	input_buffer_set_text(&buffer, "éx")
	input_buffer_move_cursor_start(&buffer)
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove combining grapheme")
	assert(
		input_buffer_string(&buffer) == "x",
		"expected delete to retain combining grapheme integrity",
	)
	input_buffer_move_cursor_end(&buffer)
	assert(!input_buffer_delete_at_cursor(&buffer), "expected delete at end to do nothing")
	_ = t
}

@(test)
test_input_buffer_handles_multibyte_graphemes :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "café")
	assert(input_buffer_cursor_position(&buffer) == 4, "expected cursor to count graphemes")
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move left over é")
	input_buffer_push_text(&buffer, "X")

	assert(input_buffer_string(&buffer) == "cafXé", "expected insertion before full é grapheme")
	assert(input_buffer_backspace(&buffer), "expected backspace to remove inserted text")
	assert(input_buffer_string(&buffer) == "café", "expected backspace to preserve UTF-8 text")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move right over é")
	assert(input_buffer_backspace(&buffer), "expected backspace to remove full é grapheme")
	assert(input_buffer_string(&buffer) == "caf", "expected full multi-byte grapheme removal")
	_ = t
}

@(test)
test_input_buffer_handles_combining_graphemes :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "é")
	assert(
		input_buffer_cursor_position(&buffer) == 1,
		"expected combining mark to share cursor cell",
	)
	assert(input_buffer_backspace(&buffer), "expected backspace to remove combined grapheme")
	assert(input_buffer_string(&buffer) == "", "expected combining grapheme to be removed at once")
	assert(input_buffer_cursor_position(&buffer) == 0, "expected cursor to return to start")
	_ = t
}

@(test)
test_app_handle_input_byte_accumulates_utf8_text :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	text := "é"

	assert(!app_handle_input_byte(&state, text[0]), "expected first UTF-8 byte to wait")
	assert(app_handle_input_byte(&state, text[1]), "expected complete UTF-8 sequence to insert")

	assert(input_buffer_string(&state.input) == "é", "expected multi-byte input to be preserved")
	assert(
		input_buffer_cursor_position(&state.input) == 1,
		"expected cursor to count one grapheme",
	)
	_ = t
}

@(test)
test_parse_slash_command :: proc(t: ^testing.T) {
	chat := parse_slash_command("hello")
	assert(!chat.isCommand, "expected regular input to stay chat text")

	exit := parse_slash_command("/exit")
	assert(exit.isCommand, "expected slash input to parse as command")
	assert(exit.kind == .Exit, "expected /exit to map to Exit command")

	config := parse_slash_command("/config provider ollama")
	assert(config.kind == .Config, "expected /config to map to Config command")
	assert(config.args == "provider ollama", "expected command args to be preserved")
	models := parse_slash_command("/models")
	assert(models.kind == .Unknown, "expected /models to be unsupported")

	skills := parse_slash_command("/skills")
	assert(skills.kind == .Unknown, "expected /skills to be unsupported")

	unknown := parse_slash_command("/wat")
	assert(unknown.kind == .Unknown, "expected unknown slash command to be marked unknown")

	stop := parse_slash_command("/stop")
	assert(stop.kind == .Stop, "expected /stop to map to Stop command")

	cancel := parse_slash_command("/cancel")
	assert(cancel.kind == .Stop, "expected /cancel to map to Stop command")

	clear := parse_slash_command("/clear")
	assert(clear.kind == .Clear, "expected /clear to map to Clear command")
	_ = t
}

@(test)
test_retired_slash_commands_are_unknown_and_omitted_from_help :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	app_run_command(&state, parse_slash_command("/models"))
	assert(state.status == "Unknown command", "expected /models to be unsupported")

	app_run_command(&state, parse_slash_command("/skills"))
	assert(state.status == "Unknown command", "expected /skills to be unsupported")

	app_run_command(&state, parse_slash_command("/help"))
	assert(
		state.history[len(state.history) - 1].content ==
		"Commands: /exit, /config, /help, /stop, /clear",
		"expected help to list only supported commands",
	)
	_ = t
}

@(test)
test_app_loads_and_clears_persistent_input_history :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-app-history-*", context.temp_allocator)
	assert(tempErr == nil, "expected temporary home directory")
	defer os.remove_all(home)

	workingDirectory, workingDirectoryErr := os.get_working_directory(context.temp_allocator)
	assert(workingDirectoryErr == nil, "expected current working directory")
	history := [1]string{"saved input"}
	assert(
		save_input_history_to_file(home, workingDirectory, history[:]) == .None,
		"expected persistent history to save",
	)

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)
	state.mode = .Chat
	assert(
		len(state.inputHistory) == 1,
		"expected persistent history to load during initialization",
	)
	assert(state.inputHistory[0] == "saved input", "expected loaded input history entry")

	app_record_input_history(&state, "new input")
	loaded, loadErr := load_input_history_from_file(home, workingDirectory, context.temp_allocator)
	defer {
		for &entry in loaded {
			entry = ""
		}
		delete(loaded)
	}
	assert(loadErr == .None, "expected new input to persist immediately")
	assert(len(loaded) == 2, "expected recorded input in persistent history")
	append_history(&state, .User, "chat history")
	state.historyScrollOffset = 1

	input_buffer_push_text(&state.input, "/clear")
	app_submit_input(&state)
	assert(len(state.inputHistory) == 0, "expected clear command to reset in-memory history")
	assert(len(state.history) == 0, "expected clear command to reset panel history")
	assert(state.historyScrollOffset == 0, "expected clear command to reset panel scroll position")
	assert(state.status == "Input history cleared", "expected clear command success status")
	_, missingErr := load_input_history_from_file(home, workingDirectory, context.temp_allocator)
	assert(missingErr == .Not_Found, "expected clear command to remove persistent history")
	_ = t
}

@(test)
test_app_submit_handles_commands_and_chat :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	input_buffer_push_text(&state.input, "/config")
	app_submit_input(&state)
	assert(state.mode == .Config, "expected /config to switch app mode")
	assert(state.status == "Config: arrows/Tab, Enter, Esc", "expected /config modal status")
	assert(len(state.inputHistory) == 0, "expected commands to stay out of input history")

	input_buffer_push_text(&state.input, "hello")
	app_submit_input(&state)
	assert(len(state.inputHistory) == 1, "expected chat input to enter input history")
	assert(state.inputHistory[0] == "hello", "expected chat input history entry")
	assert(len(state.history) >= 3, "expected chat submit to append history entries")
	assert(state.history[len(state.history) - 2].role == .User, "expected user history entry")
	assert(
		state.history[len(state.history) - 1].role == .Assistant,
		"expected assistant error entry",
	)
	assert(
		state.history[len(state.history) - 1].content == "No model selected",
		"expected missing model to be reported in history",
	)

	input_buffer_push_text(&state.input, "/exit")
	app_submit_input(&state)
	assert(state.shouldQuit, "expected /exit to request app shutdown")
	assert(len(state.inputHistory) == 1, "expected exit command to stay out of input history")
	_ = t
}

@(test)
test_app_build_ai_messages_filters_history :: proc(t: ^testing.T) {
	history := []History_Entry {
		{role = .System, content = "system"},
		{role = .User, content = "hello"},
		{role = .Assistant, content = "hi"},
		{role = .Tool, content = "tool output"},
		{role = .Assistant, content = ""},
	}

	messages := app_build_ai_messages(history, context.temp_allocator)
	assert(len(messages) == 3, "expected system, user, and non-empty assistant messages")
	assert(messages[0].role == ai.Message_Role.System, "expected system role to map")
	assert(messages[1].role == ai.Message_Role.User, "expected user role to map")
	assert(messages[2].role == ai.Message_Role.Assistant, "expected assistant role to map")
	assert(messages[2].content == "hi", "expected assistant content to be preserved")
	_ = t
}

@(test)
test_stop_command_requests_stream_cancel :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	state.stream.active = true
	app_run_command(&state, parse_slash_command("/stop"))
	assert(state.status == "Canceling assistant stream", "expected /stop to update status")
	assert(state.stream.cancelRequested, "expected /stop to request cancellation")
	_ = t
}

@(test)
test_chat_input_arrow_keys_move_cursor_and_insert :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(app_handle_input_byte(&state, 'a'), "expected printable byte to update input")
	assert(app_handle_input_byte(&state, 'b'), "expected printable byte to update input")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'D'), "expected left arrow to move cursor")
	assert(app_handle_input_byte(&state, 'X'), "expected insertion after cursor movement")

	assert(input_buffer_string(&state.input) == "aXb", "expected left arrow insertion")
	assert(input_buffer_cursor_position(&state.input) == 2, "expected cursor after inserted byte")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'C'), "expected right arrow to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 3, "expected cursor at end")
	_ = t
}

@(test)
test_chat_input_ctrl_c_does_not_quit_without_selection :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(app_handle_input_byte(&state, 3), "expected Ctrl+C to be handled")
	assert(!state.shouldQuit, "expected Ctrl+C to preserve the running app")
	assert(state.status == "No selection to copy", "expected missing selection status")
	_ = t
}

@(test)
test_chat_input_supports_home_end_delete_and_ctrl_navigation :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	input_buffer_push_text(&state.input, "abcd")
	assert(app_handle_input_byte(&state, 1), "expected Ctrl+A to select input")
	assert(input_buffer_has_selection(&state.input), "expected Ctrl+A selection")
	assert(input_buffer_selection_text(&state.input) == "abcd", "expected Ctrl+A to select all")
	assert(!app_handle_input_byte(&state, 0x1b), "expected left arrow escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected left arrow CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'D'), "expected left arrow to collapse selection")
	assert(
		input_buffer_cursor_position(&state.input) == 0,
		"expected left arrow at selection start",
	)
	assert(app_handle_input_byte(&state, 5), "expected Ctrl+E to move to end")
	assert(input_buffer_cursor_position(&state.input) == 4, "expected Ctrl+E at end")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'H'), "expected direct Home to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 0, "expected direct Home at start")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '4'), "expected numeric End parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected numeric End to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 4, "expected numeric End at end")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '7'), "expected numeric Home parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected numeric Home to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 0, "expected numeric Home at start")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '8'), "expected alternate End parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected alternate End to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 4, "expected alternate End at end")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'F'), "expected direct End to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 4, "expected direct End at end")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '1'), "expected alternate Home parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected alternate Home to move cursor")
	assert(input_buffer_cursor_position(&state.input) == 0, "expected alternate Home at start")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'C'), "expected right arrow to move cursor")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '3'), "expected Delete parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected Delete to remove cursor grapheme")
	assert(
		input_buffer_string(&state.input) == "acd",
		"expected Delete to remove grapheme at cursor",
	)
	assert(
		input_buffer_cursor_position(&state.input) == 1,
		"expected Delete to retain cursor position",
	)
	_ = t
}

@(test)
test_chat_input_discards_incomplete_numeric_csi_sequence :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '3'), "expected Delete parameter to wait")
	assert(app_flush_pending_input(&state), "expected pending CSI sequence to be discarded")
	assert(app_handle_input_byte(&state, 'x'), "expected input after discarded CSI to insert")
	assert(
		input_buffer_string(&state.input) == "x",
		"expected discarded CSI bytes to stay out of input",
	)
	_ = t
}

@(test)
test_chat_input_pastes_multiline_utf8_and_extends_selection :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	paste := "\x1b[200~one\né\x1b[201~"
	for index := 0; index < len(paste); index += 1 {
		app_handle_input_byte(&state, paste[index])
	}
	assert(input_buffer_string(&state.input) == "one\né", "expected bracketed paste text")
	assert(input_buffer_line_count(&state.input) == 2, "expected pasted newline to remain input")

	assert(!app_handle_input_byte(&state, 0x1b), "expected shift-left escape prefix")
	assert(!app_handle_input_byte(&state, '['), "expected shift-left CSI prefix")
	assert(!app_handle_input_byte(&state, '1'), "expected modified CSI parameter")
	assert(!app_handle_input_byte(&state, ';'), "expected modified CSI separator")
	assert(!app_handle_input_byte(&state, '2'), "expected shift modifier")
	assert(app_handle_input_byte(&state, 'D'), "expected shift-left to extend selection")
	assert(input_buffer_selection_text(&state.input) == "é", "expected selected final grapheme")
	_ = t
}

@(test)
test_chat_input_supports_ctrl_and_shift_insert :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	input_buffer_push_text(&state.input, "copy")
	input_buffer_select_all(&state.input)
	ctrlInsert := "\x1b[2;5~"
	for index := 0; index < len(ctrlInsert); index += 1 {
		app_handle_input_byte(&state, ctrlInsert[index])
	}
	assert(state.status == "Copied input selection", "expected Ctrl+Insert to copy selection")

	shiftInsert := "\x1b[2;2~"
	for index := 0; index < len(shiftInsert); index += 1 {
		app_handle_input_byte(&state, shiftInsert[index])
	}
	paste := "\x1b[200~pasted\x1b[201~"
	for index := 0; index < len(paste); index += 1 {
		app_handle_input_byte(&state, paste[index])
	}
	assert(input_buffer_string(&state.input) == "pasted", "expected Shift+Insert paste payload")
	_ = t
}

@(test)
test_history_scrolls_with_page_keys_and_mouse_wheel :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.terminal = console.Terminal_Size {
		rows    = 8,
		columns = 20,
	}
	for index := 0; index < 8; index += 1 {
		append_history(&state, .Assistant, "history entry")
	}

	assert(!app_handle_input_byte(&state, 0x1b), "expected Page Up escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected Page Up CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '5'), "expected Page Up parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected Page Up to scroll history")
	assert(state.historyScrollOffset > 0, "expected Page Up to move above the history bottom")
	assert(state.historyRenderOnly, "expected Page Up to request a history-only redraw")

	assert(!app_handle_input_byte(&state, 0x1b), "expected Page Down escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected Page Down CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '6'), "expected Page Down parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected Page Down to scroll history")
	assert(state.historyScrollOffset == 0, "expected Page Down to return to the history bottom")

	assert(!app_handle_input_byte(&state, 0x1b), "expected wheel escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected wheel CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '<'), "expected SGR wheel prefix to wait")
	assert(!app_handle_input_byte(&state, '6'), "expected SGR wheel data to wait")
	assert(!app_handle_input_byte(&state, '4'), "expected SGR wheel data to wait")
	assert(!app_handle_input_byte(&state, ';'), "expected SGR wheel separator to wait")
	assert(!app_handle_input_byte(&state, '2'), "expected SGR wheel column to wait")
	assert(!app_handle_input_byte(&state, ';'), "expected SGR wheel separator to wait")
	assert(!app_handle_input_byte(&state, '2'), "expected SGR wheel row to wait")
	assert(app_handle_input_byte(&state, 'M'), "expected wheel-up event to scroll history")
	assert(state.historyScrollOffset > 0, "expected wheel-up to move above the history bottom")

	assert(
		app_handle_mouse_sequence(&state, "\x1b[<65;2;2M"),
		"expected in-panel wheel-down to scroll history",
	)
	assert(state.historyScrollOffset == 0, "expected wheel-down to return to the history bottom")
	assert(
		!app_handle_mouse_sequence(&state, "\x1b[<64;2;7M"),
		"expected wheel input outside the history panel to be ignored",
	)
	assert(state.historyScrollOffset == 0, "expected ignored wheel input to retain the viewport")
	_ = t
}

@(test)
test_input_panel_mouse_drag_selects_graphemes :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.terminal = console.Terminal_Size {
		rows    = 12,
		columns = 20,
	}
	input_buffer_push_text(&state.input, "abcdef")

	assert(
		app_handle_mouse_sequence(&state, "\x1b[<0;2;10M"),
		"expected input press to start selection",
	)
	assert(
		app_handle_mouse_sequence(&state, "\x1b[<32;4;10M"),
		"expected input drag to extend selection",
	)
	assert(
		app_handle_mouse_sequence(&state, "\x1b[<0;4;10m"),
		"expected input release to finish selection",
	)
	assert(input_buffer_selection_text(&state.input) == "abc", "expected dragged input text")
	_ = t
}

@(test)
test_history_panel_mouse_drag_copies_literal_display_text :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.terminal = console.Terminal_Size {
		rows    = 12,
		columns = 20,
	}

	assert(
		app_handle_mouse_sequence(&state, "\x1b[<0;2;2M"),
		"expected history press to start selection",
	)
	assert(
		app_handle_mouse_sequence(&state, "\x1b[<32;7;2M"),
		"expected history drag to extend selection",
	)
	assert(
		app_handle_mouse_sequence(&state, "\x1b[<0;7;2m"),
		"expected history release to finish selection",
	)
	assert(app_has_history_selection(&state), "expected active history selection")
	assert(
		app_history_selection_text(&state, context.temp_allocator) == "system",
		"expected history selection to copy literal role label text",
	)
	_ = t
}

@(test)
test_history_selection_renders_highlight :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.historySelection = History_Selection {
		anchorLine   = 0,
		anchorColumn = 2,
		line         = 0,
		column       = 8,
	}

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)
	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[103ms\x1b[0m"),
		"expected selected history grapheme highlight",
	)
	_ = t
}

@(test)
test_history_resets_to_bottom_for_new_and_streamed_text :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.terminal = console.Terminal_Size {
		rows    = 8,
		columns = 20,
	}
	for index := 0; index < 8; index += 1 {
		append_history(&state, .Assistant, "history entry")
	}
	assert(app_scroll_history_page(&state, 1), "expected history to have scrollable content")
	assert(state.historyScrollOffset > 0, "expected page scroll to move above the bottom")

	append_history(&state, .User, "new entry")
	assert(state.historyScrollOffset == 0, "expected new history entry to return to the bottom")

	assert(app_scroll_history_page(&state, 1), "expected history to remain scrollable")
	state.stream.assistantIndex = len(state.history) - 1
	assistant_stream_append_partial(&state.stream, "streamed entry")
	assert(app_sync_assistant_history_entry(&state), "expected streamed content to update history")
	assert(
		state.historyScrollOffset == 0,
		"expected streamed history text to return to the bottom",
	)
	assert(
		state.history[state.stream.assistantIndex].cachedLineCount == 0,
		"expected streamed content to invalidate its wrapping cache",
	)
	_ = t
}

@(test)
test_thinking_spinner_hides_reasoning_and_yields_to_content :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .Assistant, "")
	state.stream.assistantIndex = len(state.history) - 1
	state.stream.active = true

	assert(
		assistant_stream_delta_callback(
			ai.Chat_Stream_Delta{content = "Hidden reasoning", isThinking = true},
			rawptr(&state.stream),
		),
		"expected thinking delta callback to continue streaming",
	)
	assert(
		len(state.stream.partialBuffer) == 0,
		"expected thinking text to stay out of the partial response buffer",
	)
	assert(app_poll_assistant_stream(&state), "expected thinking state to request a redraw")
	assert(state.historyRenderOnly, "expected thinking state to request a history-only redraw")
	assert(
		history_display_line(&state, state.stream.assistantIndex, context.temp_allocator) ==
		"assistant: " + SPINNER_FRAMES[0],
		"expected first spinner frame in the pending assistant entry",
	)

	state.historyRenderOnly = false
	assert(
		assistant_stream_delta_callback(
			ai.Chat_Stream_Delta{content = "Visible answer"},
			rawptr(&state.stream),
		),
		"expected content delta callback to continue streaming",
	)
	assert(app_poll_assistant_stream(&state), "expected content delta to request a redraw")
	assert(
		state.history[state.stream.assistantIndex].content == "Visible answer",
		"expected only normal content in assistant history",
	)
	assert(
		history_display_line(&state, state.stream.assistantIndex, context.temp_allocator) ==
		"assistant: Visible answer",
		"expected normal content to replace the spinner",
	)
	_ = t
}

@(test)
test_thinking_spinner_invalidates_history_cache_and_clears :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .Assistant, "")
	state.stream.assistantIndex = len(state.history) - 1
	state.stream.active = true
	_ = history_entry_line_count(&state, state.stream.assistantIndex, 20)
	assert(
		state.history[state.stream.assistantIndex].cachedLineCount > 0,
		"expected history line count to be cached",
	)

	assert(
		assistant_stream_delta_callback(
			ai.Chat_Stream_Delta{content = "Hidden reasoning", isThinking = true},
			rawptr(&state.stream),
		),
		"expected thinking delta callback to continue streaming",
	)
	assert(
		app_poll_assistant_stream(&state),
		"expected spinner visibility change to request a redraw",
	)
	assert(
		state.history[state.stream.assistantIndex].cachedLineCount == 0,
		"expected spinner visibility change to invalidate the wrapping cache",
	)
	state.stream.spinnerLastFrame = {}
	spinnerUpdate := app_update_assistant_stream_spinner(&state.stream)
	assert(spinnerUpdate.dirty, "expected elapsed spinner interval to request a redraw")
	assert(
		!spinnerUpdate.visibilityChanged,
		"expected frame changes to preserve spinner visibility",
	)
	assert(
		app_assistant_stream_spinner_frame(&state) == SPINNER_FRAMES[1],
		"expected elapsed spinner interval to advance to the next frame",
	)
	assert(
		app_clear_assistant_stream_thinking(&state.stream),
		"expected visible spinner state to clear",
	)
	assert(
		app_assistant_stream_spinner_frame(&state) == "",
		"expected cleared stream state to hide the spinner",
	)
	_ = t
}

@(test)
test_chat_input_history_uses_up_down_arrows :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	input_buffer_push_text(&state.input, "first entry")
	app_submit_input(&state)
	input_buffer_push_text(&state.input, "second entry")
	app_submit_input(&state)
	input_buffer_push_text(&state.input, "draft")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'A'), "expected up arrow to recall newest history")
	assert(input_buffer_string(&state.input) == "second entry", "expected newest history entry")
	assert(
		input_buffer_cursor_position(&state.input) == len("second entry"),
		"expected cursor at end",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'A'), "expected second up arrow to recall older history")
	assert(input_buffer_string(&state.input) == "first entry", "expected older history entry")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'B'), "expected down arrow to recall newer history")
	assert(input_buffer_string(&state.input) == "second entry", "expected newer history entry")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'B'), "expected down arrow to restore draft")
	assert(input_buffer_string(&state.input) == "draft", "expected draft restoration")
	_ = t
}

@(test)
test_capability_incompatible_config_model_selection_is_rejected :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	originalProvider := state.config.selectedProvider
	originalModel := state.config.selectedModel
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone("ollama", context.allocator),
			providerType = .Ollama,
			model = strings.clone("embedding", context.allocator),
			supportsEmbeddings = true,
		},
	)

	app_select_config_model(&state, 0)
	assert(
		state.config.selectedProvider == originalProvider,
		"expected rejected chat selection to keep provider",
	)
	assert(
		state.config.selectedModel == originalModel,
		"expected rejected chat selection to keep model",
	)
	assert(
		state.status == "Selected model does not support chat tools",
		"expected chat rejection status",
	)

	app_select_config_embedding_model(&state, 0)
	assert(
		state.config.embeddingModel == "embedding",
		"expected embedding selection to accept capability",
	)
	_ = t
}

@(test)
test_config_modal_opens_split_provider_settings :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.config.providers[0].apiKey = "secret-key"

	app_show_config(&state)
	sequence := render_app_frame_sequence(&state, 24, 100, context.temp_allocator)

	assert(state.mode == .Config, "expected config modal mode")
	assert(state.configCategory == .Providers, "expected providers category by default")
	assert(len(state.configSettings) >= 10, "expected provider controls")
	assert(contains_string(sequence, " Configuration "), "expected config modal title")
	assert(contains_string(sequence, "Categories"), "expected category pane")
	assert(contains_string(sequence, "Providers"), "expected providers category")
	assert(contains_string(sequence, "API key: ********"), "expected masked API key")
	assert(!contains_string(sequence, "secret-key"), "expected raw API key to stay hidden")
	_ = t
}

@(test)
test_config_modal_toggles_provider_enabled_and_cancels_text_edit :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings

	state.configSettingCursor = 7
	assert(app_activate_config_setting(&state), "expected enabled setting activation")
	assert(!state.config.providers[0].enabled, "expected enabled checkbox to toggle")

	state.configSettingCursor = 1
	assert(app_activate_config_setting(&state), "expected name text setting activation")
	assert(state.configEditing, "expected text editing mode")
	assert(app_handle_input_byte(&state, 'x'), "expected text input")
	assert(app_handle_input_byte(&state, 0x1b), "expected text edit cancellation")
	assert(!state.configEditing, "expected text editing to stop")
	assert(state.config.providers[0].name == "ollama", "expected escaped edit to preserve name")
	_ = t
}

@(test)
test_config_modal_commits_provider_text_edit :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings
	state.configSettingCursor = 3

	assert(app_activate_config_setting(&state), "expected endpoint text setting activation")
	assert(app_handle_input_byte(&state, '/'), "expected endpoint text input")
	assert(app_handle_input_byte(&state, 'v'), "expected endpoint text input")
	assert(app_handle_input_byte(&state, '1'), "expected endpoint text input")
	assert(app_handle_input_byte(&state, '\r'), "expected endpoint text commit")
	assert(
		state.config.providers[0].endpoint == "http://localhost:11434/v1",
		"expected committed endpoint",
	)
	_ = t
}

@(test)
test_compute_app_layout_places_status_last :: proc(t: ^testing.T) {
	layout := compute_app_layout(24, 80, 3)
	assert(layout.statusBar.top_row == 24, "expected status bar to occupy final row")
	assert(layout.statusBar.bottom_row == 24, "expected status bar to be one row tall")
	assert(layout.inputPanel.bottom_row == 23, "expected input panel to end above status bar")
	assert(layout.historyPanel.top_row == 1, "expected history panel to start at first row")
	assert(
		layout.inputPanel.bottom_row - layout.inputPanel.top_row + 1 == 5,
		"expected input panel to grow to input lines plus border",
	)
	_ = t
}

@(test)
test_context_usage_status_text_and_right_clipping :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.stream.usage = ai.Chat_Usage {
		inputTokens    = 12500,
		hasInputTokens = true,
	}
	state.stream.contextWindowTokens = 32000

	status := app_context_usage_status_text(&state, context.temp_allocator)
	assert(status == "ctx 12.5k/32k 39%", "expected compact context usage status")
	clipped := right_clipped_text(status, 6)
	assert(text_display_width(clipped) <= 6, "expected right-clipped indicator to fit")
	assert(
		strings.has_suffix(status, clipped),
		"expected right clipping to retain the indicator end",
	)
	_ = t
}

@(test)
test_render_app_frame_contains_panels_and_status :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.status = "Testing"
	input_buffer_push_text(&state.input, "hello\nthere")

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)
	assert(
		contains_string(sequence, console.clear_screen_home_sequence()),
		"expected full frame render to clear the screen",
	)
	assert(contains_string(sequence, HISTORY_TITLE), "expected history panel title")
	assert(contains_string(sequence, INPUT_TITLE), "expected input panel title")
	assert(
		contains_string(sequence, "system: Mimir the terminal harness is ready."),
		"expected history text",
	)
	assert(contains_string(sequence, "hello"), "expected input text first line")
	assert(contains_string(sequence, "there"), "expected input text second line")
	assert(contains_string(sequence, "Testing"), "expected status text")
	_ = t
}

@(test)
test_render_history_preserves_multiline_assistant_content :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .User, "question")
	append_history(&state, .Assistant, "first line\nsecond line")

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)

	assert(contains_string(sequence, "assistant: first line"), "expected first assistant line")
	assert(contains_string(sequence, "second line"), "expected later assistant lines")
	_ = t
}

@(test)
test_render_app_frame_draws_input_cursor_cell :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	input_buffer_push_text(&state.input, "ab")
	input_buffer_move_cursor_left(&state.input)
	state.cursorBlinkOn = true

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		contains_string(sequence, "a\x1b[0m\x1b[30m\x1b[106mb\x1b[0m"),
		"expected cursor cell to render with bright cyan background",
	)
	_ = t
}

@(test)
test_render_app_input_panel_skips_screen_clear :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.status = "Testing"
	input_buffer_push_text(&state.input, "hello")

	sequence := render_app_input_panel_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		!contains_string(sequence, console.clear_screen_sequence()),
		"expected input-only render to avoid full screen clear",
	)
	assert(contains_string(sequence, INPUT_TITLE), "expected input panel title")
	assert(contains_string(sequence, "hello"), "expected input text")
	assert(!contains_string(sequence, HISTORY_TITLE), "expected history panel to be untouched")
	assert(!contains_string(sequence, "Testing"), "expected status bar to be untouched")
	_ = t
}

@(test)
test_render_app_history_panel_skips_screen_clear :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.status = "Testing"
	input_buffer_push_text(&state.input, "hello")

	sequence := render_app_history_panel_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		!contains_string(sequence, console.clear_screen_sequence()),
		"expected history-only render to avoid full screen clear",
	)
	assert(
		contains_string(sequence, HISTORY_TITLE),
		"expected history-only render to draw history",
	)
	assert(
		!contains_string(sequence, INPUT_TITLE),
		"expected history-only render to leave input untouched",
	)
	assert(
		!contains_string(sequence, "Testing"),
		"expected history-only render to leave status untouched",
	)
	_ = t
}

@(test)
test_render_app_input_panel_draws_cursor_cell :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	input_buffer_push_text(&state.input, "ab")
	input_buffer_move_cursor_left(&state.input)
	state.cursorBlinkOn = true

	sequence := render_app_input_panel_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		contains_string(sequence, "a\x1b[0m\x1b[30m\x1b[106mb\x1b[0m"),
		"expected input-only render to draw the cursor cell",
	)
	_ = t
}

@(test)
test_render_app_frame_draws_unicode_input_cursor_cell :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	input_buffer_push_text(&state.input, "cé")
	input_buffer_move_cursor_left(&state.input)
	state.cursorBlinkOn = true

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		contains_string(sequence, "c\x1b[0m\x1b[30m\x1b[106mé\x1b[0m"),
		"expected cursor cell to render the full multi-byte grapheme",
	)
	_ = t
}

@(test)
test_write_text_lines_wraps_panel_text :: proc(t: ^testing.T) {
	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	region := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 5,
		right_column = 5,
	}

	write_text_lines(&batch, region, "one two three")

	assert(
		console.batch_sequence(&batch) == "\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hthree",
		"expected panel text to wrap at word boundaries",
	)
	_ = t
}

@(test)
test_write_text_lines_hard_breaks_long_words :: proc(t: ^testing.T) {
	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	region := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 5,
		right_column = 4,
	}

	write_text_lines(&batch, region, "abcdefghij")

	assert(
		console.batch_sequence(&batch) == "\x1b[1;1Habcd\x1b[2;1Hefgh\x1b[3;1Hij",
		"expected long words to hard-break when no whitespace fits",
	)
	_ = t
}

@(test)
test_write_text_lines_wraps_wide_graphemes :: proc(t: ^testing.T) {
	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	region := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 5,
		right_column = 4,
	}

	write_text_lines(&batch, region, "日本語")

	assert(
		console.batch_sequence(&batch) == "\x1b[1;1H日本\x1b[2;1H語",
		"expected wrapping to respect wide grapheme display widths",
	)
	_ = t
}

@(test)
test_write_text_lines_preserves_blank_lines :: proc(t: ^testing.T) {
	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	region := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 5,
		right_column = 5,
	}

	write_text_lines(&batch, region, "a\n\nb")

	assert(
		console.batch_sequence(&batch) == "\x1b[1;1Ha\x1b[2;1H\x1b[3;1Hb",
		"expected explicit blank lines to consume panel rows",
	)
	_ = t
}

@(test)
test_render_app_frame_wraps_and_sizes_input_panel :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	input_buffer_push_text(&state.input, "alpha beta gamma")

	sequence := render_app_frame_sequence(&state, 10, 12, context.temp_allocator)

	assert(contains_string(sequence, "\x1b[6;1H┌"), "expected wrapped input to grow panel")
	assert(contains_string(sequence, "alpha beta"), "expected first wrapped input row")
	assert(contains_string(sequence, "gamma"), "expected second wrapped input row")
	_ = t
}

@(test)
test_render_history_wraps_panel_text :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .User, "alpha beta gamma")

	sequence := render_app_frame_sequence(&state, 8, 12, context.temp_allocator)

	assert(contains_string(sequence, "alpha beta"), "expected history text above the bottom row")
	assert(
		contains_string(sequence, "gamma"),
		"expected history text to stay anchored at the bottom",
	)
	_ = t
}

@(test)
test_config_and_skill_paths :: proc(t: ^testing.T) {
	assert(
		config_path("/home/test", context.temp_allocator) ==
		"/home/test/.config/mimir/config.json",
		"expected config path under XDG-style user config directory",
	)
	assert(
		global_skill_dir("/home/test", context.temp_allocator) ==
		"/home/test/.config/mimir/skills",
		"expected global skills under mimir config directory",
	)
	assert(
		project_skill_dir("/repo", context.temp_allocator) == "/repo/.mimir/skills",
		"expected project skills under project .mimir directory",
	)
	assert(skill_name_from_path("/repo/.mimir/skills/odin.md") == "odin", "expected skill name")
	_ = t
}

@(test)
test_default_config_json_shape :: proc(t: ^testing.T) {
	config := default_ollama_config(context.temp_allocator)
	defer {
		delete(config.providers)
		delete(config.mcpServers)
		delete(config.skillPaths)
	}

	json := config_to_json(config, context.temp_allocator)
	assert(json[:1] == "{", "expected config JSON object")
	assert(
		contains_string(json, "\"endpoint\": \"http://localhost:11434\""),
		"expected default config JSON to include Ollama endpoint",
	)
	assert(contains_string(json, "\"mcpServers\": []"), "expected MCP registry config key")
	assert(contains_string(json, "\"skillPaths\": []"), "expected skill path config key")
	_ = t
}

@(test)
test_default_app_state_has_registries :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(state.mode == .Chat, "expected app to start in chat mode")
	assert(state.terminal.rows == 24, "expected default terminal rows")
	assert(state.terminal.columns == 80, "expected default terminal columns")
	assert(len(state.config.providers) == 1, "expected default Ollama provider")
	assert(
		state.config.providers[0].endpoint == DEFAULT_CONFIG_ENDPOINT,
		"expected default endpoint",
	)
	assert(len(state.tools.definitions) >= 3, "expected built-in tool registry entries")
	_ = t
}

@(test)
test_app_init_with_missing_config_enters_setup_without_probe :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-app-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)

	assert(state.mode == .Setup, "expected missing config without probe to enter setup")
	assert(state.setupStep == .Endpoint, "expected setup to ask for endpoint first")
	assert(state.status == "Setup: enter Ollama endpoint", "expected setup status")
	_ = t
}

@(test)
test_app_init_with_saved_config_loads_chat_mode :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-app-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	config := default_ollama_config(context.temp_allocator)
	config.selectedModel = "llama3.2"
	config.providers[0].model = "llama3.2"
	defer {
		delete(config.providers)
		delete(config.mcpServers)
		delete(config.skillPaths)
	}
	assert(save_config_to_file(home, config) == .None, "expected test config save")

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)

	assert(state.mode == .Chat, "expected saved config to start in chat mode")
	assert(state.config.selectedModel == "llama3.2", "expected saved selected model")
	assert(len(state.config.providers) == 1, "expected saved provider to load")
	assert(state.status == "Config loaded", "expected loaded config status")
	_ = t
}

@(test)
test_setup_endpoint_submission_prompts_for_api_key :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.mode = .Setup
	state.setupStep = .Endpoint

	input_buffer_push_text(&state.input, "http://localhost:11434")
	app_submit_input(&state)

	assert(state.mode == .Setup, "expected setup mode to continue")
	assert(state.setupStep == .API_Key, "expected setup to advance to API key")
	assert(state.setupEndpoint == "http://localhost:11434", "expected setup endpoint capture")
	assert(
		state.status == "Setup: enter optional API key, or press Enter",
		"expected API key prompt status",
	)
	_ = t
}

@(test)
test_app_set_terminal_size_reports_changes :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(
		!app_set_terminal_size(&state, state.terminal),
		"expected unchanged terminal size to avoid redraw",
	)
	assert(
		app_set_terminal_size(&state, console.Terminal_Size{rows = 40, columns = 120}),
		"expected changed terminal size to request redraw",
	)
	assert(state.terminal.rows == 40, "expected terminal rows to update")
	assert(state.terminal.columns == 120, "expected terminal columns to update")
	_ = t
}

contains_string :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}

	for start := 0; start <= len(haystack) - len(needle); start += 1 {
		if haystack[start:start + len(needle)] == needle {
			return true
		}
	}
	return false
}
