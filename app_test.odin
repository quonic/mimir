package main

import "agent"
import "ai"
import "approval_safety"
import "commands"
import "console"
import "core:os"
import "core:strings"
import "core:testing"
import "input_history"
import "settings"
import "text_input"
import "tool_policy"
import "widgets"

// _send_mouse_sequence feeds a raw SGR mouse escape sequence through the same
// byte-by-byte pipeline the app's read loop uses, returning the result of the
// final (sequence-completing) byte.
_send_mouse_sequence :: proc(state: ^App_State, sequence: string) -> bool {
	handled := false
	for i := 0; i < len(sequence); i += 1 {
		handled = app_handle_input_byte(state, sequence[i])
	}
	return handled
}

@(test)
test_history_right_click_opens_context_menu :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .User, "hello world")

	handled := app_handle_mouse_sequence(
		&state,
		console.Mouse_Event{row = 2, column = 3, kind = .Press, button = .Right},
	)
	assert(handled, "expected right-click in history panel to be handled")
	assert(app_has_overlay(&state, widgets.Context_Menu), "expected a context menu to open")
	_ = t
}

@(test)
test_history_context_menu_selects_copy_immediately :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	text_input.input_buffer_push_text(&state.input, "abc")
	text_input.input_buffer_select_range(&state.input, 0, 3)

	assert(
		app_handle_mouse_sequence(
			&state,
			console.Mouse_Event{row = 2, column = 3, kind = .Press, button = .Right},
		),
		"expected right-click to open the context menu",
	)
	app_menu_overlay_activate(&state) // highlight defaults to the only item, "Copy"
	assert(state.status == "Copied input selection", "expected copy action to run immediately")
	assert(
		app_has_overlay(&state, widgets.Context_Menu),
		"expected menu to stay open during the flip animation",
	)
	_ = t
}

@(test)
test_history_context_menu_press_outside_cancels :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(
		app_handle_mouse_sequence(
			&state,
			console.Mouse_Event{row = 2, column = 3, kind = .Press, button = .Right},
		),
		"expected right-click to open the context menu",
	)
	assert(
		app_handle_menu_overlay_mouse(
			&state,
			console.Mouse_Event{row = 1, column = 1, kind = .Press, button = .Left},
		),
		"expected press outside the menu to be handled",
	)
	assert(len(state.overlayStack) == 0, "expected press outside the menu to cancel it")
	_ = t
}

@(test)
test_config_approval_method_dropdown_escape_leaves_method_unchanged :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)

	assert(app_activate_config_setting(&state), "expected approval method activation")
	assert(app_has_overlay(&state, widgets.Dropdown_List), "expected dropdown to open")
	app_pop_overlay(&state) // simulate Escape
	assert(state.config.approvalMethod == .Always_Ask, "expected approval method unchanged")
	assert(app_has_overlay(&state, Config_Overlay), "expected config modal still open")
	_ = t
}

@(test)
test_approval_modal_navigates_and_escape_denies :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(
			&state,
			tool_policy.Tool_Call{id = "write_file", filePath = "generated/output.txt"},
		),
		"expected write call to open approval modal",
	)
	assert(app_has_overlay(&state, Approval_Overlay), "expected approval mode")
	assert(state.approval.choice == .Allow_Once, "expected once approval selected initially")
	assert(app_handle_approval_input(&state, 'j'), "expected approval choice movement")
	assert(state.approval.choice == .Allow_Session, "expected session approval selected")
	assert(!app_handle_approval_input(&state, 0x1b), "expected escape sequence start")
	assert(app_handle_approval_input(&state, 'x'), "expected escape to deny approval")
	assert(len(state.overlayStack) == 0, "expected denial to restore chat mode")
	assert(state.status == "Tool call denied", "expected escape denial status")
	_ = t
}

@(test)
test_approval_modal_ignores_mouse_motion :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(
			&state,
			tool_policy.Tool_Call{id = "write_file", filePath = "generated/output.txt"},
		),
		"expected write call to open approval modal",
	)
	motion := "\x1b[<35;44;44M"
	for inputIndex := 0; inputIndex < len(motion); inputIndex += 1 {
		app_handle_input_byte(&state, motion[inputIndex])
	}
	assert(
		app_has_overlay(&state, Approval_Overlay),
		"expected mouse motion to keep approval modal open",
	)
	assert(
		state.approval.choice == .Allow_Once,
		"expected mouse motion coordinates to leave the approval choice unchanged",
	)
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
			name = "run_in_terminal",
			arguments = `{"command":"echo \"Test Shell command\"","shell":"/bin/bash"}`,
		},
		context.allocator,
	)
	assert(callOK, "expected command tool call to decode")
	assert(app_show_approval(&state, call), "expected command call to open approval modal")
	tool_policy.tool_call_destroy(&call, context.allocator)

	sequence := render_app_frame_sequence(&state, 18, 80, context.temp_allocator)
	assert(
		contains_string(sequence, `echo "Test Shell command"`),
		"expected approval modal to display retained command text",
	)
	_ = t
}

@(test)
test_approval_safety_model_prefers_explicit_selection :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.selectedModel = "chat-model"
	state.config.safetyProvider = "ollama"
	state.config.safetyModel = "safety-model"

	safetyModel, safetyModelOK := approval_safety_model_from_config(state.config)
	assert(safetyModelOK, "expected explicit safety model to resolve")
	assert(safetyModel.provider.name == "ollama", "expected configured safety provider")
	assert(safetyModel.model == "safety-model", "expected configured safety model")
	_ = t
}

@(test)
test_approval_safety_model_falls_back_to_chat_selection :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.selectedModel = "chat-model"

	safetyModel, safetyModelOK := approval_safety_model_from_config(state.config)
	assert(safetyModelOK, "expected empty safety selection to use chat model")
	assert(
		safetyModel.provider.name == settings.DEFAULT_CONFIG_PROVIDER,
		"expected chat provider fallback",
	)
	assert(safetyModel.model == "chat-model", "expected chat model fallback")
	_ = t
}

@(test)
test_approval_safety_model_rejects_partial_selection :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.config.safetyProvider = "ollama"

	_, safetyModelOK := approval_safety_model_from_config(state.config)
	assert(!safetyModelOK, "expected partial safety selection to be unavailable")
	_ = t
}

@(test)
test_approval_safety_display_text_compacts_model_response :: proc(t: ^testing.T) {
	advice := approval_safety_display_text(
		"  Safe: Reads repository status only.  \nVerdict: Safe.\n",
		context.temp_allocator,
	)
	assert(
		advice == "Safe: Reads repository status only.",
		"expected advice to retain only its first trimmed line",
	)
	_ = t
}

@(test)
test_approval_safety_display_text_truncates_at_grapheme_boundary :: proc(t: ^testing.T) {
	repeated := strings.repeat("é", APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES, context.temp_allocator)
	defer delete(repeated, context.temp_allocator)
	response := strings.concatenate({"Safe: ", repeated}, context.temp_allocator)
	defer delete(response, context.temp_allocator)
	advice := approval_safety_display_text(response, context.temp_allocator)
	assert(
		text_input.unicode_grapheme_count(advice) == APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES,
		"expected advice to be limited to the display grapheme count",
	)
	assert(strings.has_suffix(advice, "..."), "expected truncated advice to end with an ellipsis")
	_ = t
}

@(test)
test_approval_safety_blocks_input_until_analysis_completes :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(
			&state,
			tool_policy.Tool_Call{id = "write_file", filePath = "generated/output.txt"},
		),
		"expected write call to open approval modal",
	)
	assert(
		!app_handle_approval_input_with_safety_ready(&state, '4', false),
		"expected pending safety analysis to ignore choice",
	)
	assert(
		!app_handle_approval_input_with_safety_ready(&state, '\r', false),
		"expected pending safety analysis to ignore approval",
	)
	assert(
		app_has_overlay(&state, Approval_Overlay),
		"expected pending analysis to keep modal open",
	)
	assert(state.approval.choice == .Allow_Once, "expected pending analysis to preserve selection")

	approval_safety.mark_unavailable(&state.approval.safety)
	assert(app_handle_approval_input(&state, '4'), "expected unavailable advice to unlock choices")
	assert(app_handle_approval_input(&state, '\r'), "expected unavailable advice to allow denial")
	assert(len(state.overlayStack) == 0, "expected denial after unavailable advice to close modal")
	_ = t
}

@(test)
test_approval_modal_renders_unavailable_safety_advice :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		app_show_approval(
			&state,
			tool_policy.Tool_Call{id = "run_in_terminal", command = "git status"},
		),
		"expected command call to open approval modal",
	)
	approval_safety.mark_unavailable(&state.approval.safety)
	sequence := render_app_frame_sequence(&state, 24, 80, context.temp_allocator)
	assert(
		contains_string(sequence, "Safety advice: unavailable"),
		"expected unavailable safety advice in command approval modal",
	)
	_ = t
}

@(test)
test_app_tool_definitions_include_ollama :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	ollamaTools := app_tool_definitions_for_provider(&state, .Ollama, context.allocator)
	defer delete(ollamaTools)
	assert(len(ollamaTools) == 10, "expected Ollama to receive all built-in tools")

	_ = t
}

@(test)
test_app_refresh_skills_does_not_mutate_active_agent :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	state.agentHost.activeAgentID = agent.Agent_ID(1)
	state.agentHost.runtime.instances = make(
		[dynamic]agent.Agent_Instance,
		0,
		1,
		context.allocator,
	)
	append(
		&state.agentHost.runtime.instances,
		agent.Agent_Instance{state = .Streaming, id = agent.Agent_ID(1)},
	)
	app_refresh_skills(&state)
	assert(
		state.status == "Stop the active agent before refreshing skills",
		"expected skill refresh to wait for an active agent",
	)
	_ = t
}

@(test)
test_app_skill_setting_toggles_persisted_disabled_name :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "app_skill_setting_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	skillRoot := strings.concatenate({project, "/.mimir/skills/demo"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	skillPath := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			skillPath,
			"---\nname: demo\ndescription: Demo skill\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)

	state := app_init(context.allocator)
	defer app_destroy(&state)
	settings.skill_registry_load(&state.skills, "", project)
	state.configCategory = .Skills
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)
	assert(len(state.configSettings) == 2, "expected refresh and skill toggle settings")
	state.configSettingCursor = 1
	assert(app_activate_config_setting(&state), "expected skill toggle activation")
	assert(len(state.config.disabledSkills) == 1, "expected disabled skill to persist")
	assert(state.config.disabledSkills[0] == "demo", "expected demo skill to be disabled")
	assert(app_activate_config_setting(&state), "expected skill toggle activation")
	assert(len(state.config.disabledSkills) == 0, "expected disabled skill to be removed")
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
	state.config.providers = make([dynamic]settings.Provider_Config, 0, 1, context.temp_allocator)
	defer delete(state.config.providers)
	append(
		&state.config.providers,
		settings.Provider_Config {
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
test_app_handle_input_byte_accumulates_utf8_text :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	text := "é"

	assert(!app_handle_input_byte(&state, text[0]), "expected first UTF-8 byte to wait")
	assert(app_handle_input_byte(&state, text[1]), "expected complete UTF-8 sequence to insert")

	assert(
		text_input.input_buffer_string(&state.input) == "é",
		"expected multi-byte input to be preserved",
	)
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 1,
		"expected cursor to count one grapheme",
	)
	_ = t
}

@(test)
test_retired_slash_commands_are_unknown_and_omitted_from_help :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	app_run_in_terminal(&state, commands.parse_slash_command("/models"))
	assert(state.status == "Unknown command", "expected /models to be unsupported")

	app_run_in_terminal(&state, commands.parse_slash_command("/skills"))
	assert(state.status == "Unknown command", "expected /skills to be unsupported")

	app_run_in_terminal(&state, commands.parse_slash_command("/help"))
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
		input_history.save(home, workingDirectory, history[:]) == .None,
		"expected persistent history to save",
	)

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)
	state.screen = .Chat
	assert(
		len(state.inputHistory) == 1,
		"expected persistent history to load during initialization",
	)
	assert(state.inputHistory[0] == "saved input", "expected loaded input history entry")

	app_record_input_history(&state, "new input")
	loaded, loadErr := input_history.load(home, workingDirectory, context.temp_allocator)
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

	text_input.input_buffer_push_text(&state.input, "/clear")
	app_submit_input(&state)
	assert(len(state.inputHistory) == 0, "expected clear command to reset in-memory history")
	assert(len(state.history) == 0, "expected clear command to reset panel history")
	assert(state.historyScrollOffset == 0, "expected clear command to reset panel scroll position")
	assert(state.status == "Input history cleared", "expected clear command success status")
	_, missingErr := input_history.load(home, workingDirectory, context.temp_allocator)
	assert(missingErr == .Not_Found, "expected clear command to remove persistent history")
	_ = t
}

@(test)
test_app_submit_handles_commands_and_chat :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "/config")
	app_submit_input(&state)
	assert(app_has_overlay(&state, Config_Overlay), "expected /config to switch app mode")
	assert(state.status == "Config: arrows/Tab, Enter, Esc", "expected /config modal status")
	assert(len(state.inputHistory) == 0, "expected commands to stay out of input history")

	text_input.input_buffer_push_text(&state.input, "hello")
	app_submit_input(&state)
	assert(len(state.inputHistory) == 1, "expected chat input to enter input history")
	assert(state.inputHistory[0] == "hello", "expected chat input history entry")
	assert(len(state.history) == 2, "expected chat submit to append only the user entry")
	assert(state.history[len(state.history) - 1].role == .User, "expected user history entry")
	assert(state.history[len(state.history) - 1].content == "hello", "expected user content")
	assert(state.status == "No model selected", "expected missing model status")

	text_input.input_buffer_push_text(&state.input, "/exit")
	app_submit_input(&state)
	assert(state.shouldQuit, "expected /exit to request app shutdown")
	assert(len(state.inputHistory) == 1, "expected exit command to stay out of input history")
	_ = t
}

@(test)
test_tab_completion_single_match_auto_completes :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/ex")
	app_handle_input_byte(&state, '\t')
	assert(
		text_input.input_buffer_string(&state.input) == "/exit",
		"expected sole match to auto-complete",
	)
	assert(!state.commandCompletionActive, "expected no dropdown for a single match")
	_ = t
}

@(test)
test_tab_completion_multi_match_opens_dropdown_and_narrows :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/c")
	app_handle_input_byte(&state, '\t')
	assert(state.commandCompletionActive, "expected multiple matches to open a dropdown")
	assert(app_has_overlay(&state, widgets.Dropdown_List), "expected Dropdown_List overlay")

	app_handle_input_byte(&state, 'o')
	assert(
		text_input.input_buffer_string(&state.input) == "/config",
		"expected narrowing to a single match to auto-complete",
	)
	assert(!state.commandCompletionActive, "expected dropdown to close on auto-complete")
	_ = t
}

@(test)
test_tab_completion_no_matches_reports_status :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/zzz")
	app_handle_input_byte(&state, '\t')
	assert(state.status == "No completions", "expected status for an unmatched prefix")
	assert(!state.commandCompletionActive, "expected no dropdown opened")
	_ = t
}

@(test)
test_tab_completion_args_region_reports_status_without_literal_tab :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/stop ")
	app_handle_input_byte(&state, '\t')
	assert(state.status == "No completions", "expected status once past the command token")
	assert(
		text_input.input_buffer_string(&state.input) == "/stop ",
		"expected no literal tab inserted in the args region",
	)
	_ = t
}

@(test)
test_tab_completion_alias_prefix_completes_to_alias :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/q")
	app_handle_input_byte(&state, '\t')
	assert(
		text_input.input_buffer_string(&state.input) == "/quit",
		"expected alias prefix to complete to its own alias, not the primary name",
	)
	_ = t
}

@(test)
test_tab_completion_escape_keeps_typed_prefix :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/c")
	app_handle_input_byte(&state, '\t')
	assert(state.commandCompletionActive, "expected dropdown to open for multiple matches")

	app_handle_input_byte(&state, 0x1b)
	app_flush_pending_input(&state) // resolve the lone Escape byte, same as the real poll timeout
	assert(!state.commandCompletionActive, "expected Escape to close the dropdown")
	assert(
		text_input.input_buffer_string(&state.input) == "/c",
		"expected Escape to keep the typed prefix",
	)
	_ = t
}

@(test)
test_tab_completion_tab_accepts_highlighted_item_like_enter :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/c")
	app_handle_input_byte(&state, '\t')
	assert(state.commandCompletionActive, "expected dropdown to open for multiple matches")

	_send_mouse_sequence(&state, "\x1b[B") // Arrow_Down: highlight moves from "cancel" to "clear"
	app_handle_input_byte(&state, '\t')
	assert(
		text_input.input_buffer_string(&state.input) == "/clear",
		"expected Tab to accept the highlighted item, same as Enter",
	)
	assert(!state.commandCompletionActive, "expected Tab acceptance to close the dropdown")
	_ = t
}

@(test)
test_tab_completion_enter_fills_input_without_running_command :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	_send_mouse_sequence(&state, "/c")
	app_handle_input_byte(&state, '\t')
	assert(state.commandCompletionActive, "expected dropdown to open for multiple matches")

	app_handle_input_byte(&state, '\r')
	assert(!state.commandCompletionActive, "expected Enter to close the dropdown")
	assert(!state.shouldQuit, "expected Enter on a completion to not execute the command")
	_ = t
}

@(test)
test_app_build_ai_messages_filters_history :: proc(t: ^testing.T) {
	history := []History_Entry {
		{role = .System, content = "system"},
		{role = .User, content = "hello"},
		{role = .Assistant, content = "hi"},
		{role = .Tool, content = "tool output"},
		{role = .Note, content = "note text"},
		{role = .Assistant, content = ""},
	}

	messages := app_build_ai_messages(history, "configured prompt", context.temp_allocator)
	assert(len(messages) == 3, "expected configured prompt, user, and assistant messages")
	assert(messages[0].role == ai.Message_Role.System, "expected system role to map")
	assert(messages[0].content == "configured prompt", "expected configured prompt first")
	assert(messages[1].role == ai.Message_Role.User, "expected user role to map")
	assert(messages[2].role == ai.Message_Role.Assistant, "expected assistant role to map")
	assert(messages[2].content == "hi", "expected assistant content to be preserved")
	_ = t
}

@(test)
test_app_build_ai_messages_empty_system_prompt_preserves_history_order :: proc(t: ^testing.T) {
	history := []History_Entry {
		{role = .System, content = "system"},
		{role = .User, content = "hello"},
		{role = .Assistant, content = "hi"},
		{role = .Tool, content = "tool output"},
		{role = .Note, content = "note text"},
		{role = .Assistant, content = ""},
	}

	messages := app_build_ai_messages(history, "", context.temp_allocator)
	assert(len(messages) == 2, "expected only non-system mapped history messages")
	assert(messages[0].role == ai.Message_Role.User, "expected user message first")
	assert(messages[0].content == "hello", "expected user content to be preserved")
	assert(messages[1].role == ai.Message_Role.Assistant, "expected assistant message second")
	assert(messages[1].content == "hi", "expected assistant content to be preserved")
	_ = t
}

@(test)
test_system_prompt_effective_respects_customization_mode :: proc(t: ^testing.T) {
	defaultPrompt := system_prompt_effective("", .Append, context.temp_allocator)
	defer delete(defaultPrompt, context.temp_allocator)
	assert(
		defaultPrompt ==
		strings.concatenate(
			{DEFAULT_SYSTEM_PROMPT, system_prompt_date(context.temp_allocator)},
			context.temp_allocator,
		),
		"expected default system prompt",
	)

	appendedPrompt := system_prompt_effective("Use tabs.", .Append, context.temp_allocator)
	defer delete(appendedPrompt, context.temp_allocator)
	assert(
		contains_string(appendedPrompt, "Additional user instructions:\nUse tabs."),
		"expected append mode to retain custom instructions",
	)

	replacedPrompt := system_prompt_effective(
		"Only user instructions.",
		.Replace,
		context.temp_allocator,
	)
	defer delete(replacedPrompt, context.temp_allocator)
	assert(
		replacedPrompt ==
		strings.concatenate(
			{"Only user instructions.", system_prompt_date(context.temp_allocator)},
			context.temp_allocator,
		),
		"expected replace mode to use custom prompt",
	)
	_ = t
}

@(test)
test_stop_command_requests_stream_cancel :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	app_run_in_terminal(&state, commands.parse_slash_command("/stop"))
	assert(state.status == "Canceling assistant stream", "expected /stop to update status")
	agentState, agentOK := agent.runtime_state(
		&state.agentHost.runtime,
		state.agentHost.activeAgentID,
	)
	assert(agentOK && agentState == .Canceled, "expected /stop to cancel the active runtime")
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

	assert(text_input.input_buffer_string(&state.input) == "aXb", "expected left arrow insertion")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 2,
		"expected cursor after inserted byte",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'C'), "expected right arrow to move cursor")
	assert(text_input.input_buffer_cursor_position(&state.input) == 3, "expected cursor at end")
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

	text_input.input_buffer_push_text(&state.input, "abcd")
	assert(app_handle_input_byte(&state, 1), "expected Ctrl+A to select input")
	assert(text_input.input_buffer_has_selection(&state.input), "expected Ctrl+A selection")
	assert(
		text_input.input_buffer_selection_text(&state.input) == "abcd",
		"expected Ctrl+A to select all",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected left arrow escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected left arrow CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'D'), "expected left arrow to collapse selection")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 0,
		"expected left arrow at selection start",
	)
	assert(app_handle_input_byte(&state, 5), "expected Ctrl+E to move to end")
	assert(text_input.input_buffer_cursor_position(&state.input) == 4, "expected Ctrl+E at end")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'H'), "expected direct Home to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 0,
		"expected direct Home at start",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '4'), "expected numeric End parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected numeric End to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 4,
		"expected numeric End at end",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '7'), "expected numeric Home parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected numeric Home to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 0,
		"expected numeric Home at start",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '8'), "expected alternate End parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected alternate End to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 4,
		"expected alternate End at end",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'F'), "expected direct End to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 4,
		"expected direct End at end",
	)
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '1'), "expected alternate Home parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected alternate Home to move cursor")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 0,
		"expected alternate Home at start",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'C'), "expected right arrow to move cursor")
	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(!app_handle_input_byte(&state, '3'), "expected Delete parameter to wait")
	assert(app_handle_input_byte(&state, '~'), "expected Delete to remove cursor grapheme")
	assert(
		text_input.input_buffer_string(&state.input) == "acd",
		"expected Delete to remove grapheme at cursor",
	)
	assert(
		text_input.input_buffer_cursor_position(&state.input) == 1,
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
		text_input.input_buffer_string(&state.input) == "x",
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
	assert(
		text_input.input_buffer_string(&state.input) == "one\né",
		"expected bracketed paste text",
	)
	assert(
		text_input.input_buffer_line_count(&state.input) == 2,
		"expected pasted newline to remain input",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected shift-left escape prefix")
	assert(!app_handle_input_byte(&state, '['), "expected shift-left CSI prefix")
	assert(!app_handle_input_byte(&state, '1'), "expected modified CSI parameter")
	assert(!app_handle_input_byte(&state, ';'), "expected modified CSI separator")
	assert(!app_handle_input_byte(&state, '2'), "expected shift modifier")
	assert(app_handle_input_byte(&state, 'D'), "expected shift-left to extend selection")
	assert(
		text_input.input_buffer_selection_text(&state.input) == "é",
		"expected selected final grapheme",
	)
	_ = t
}

@(test)
test_chat_input_supports_ctrl_and_shift_insert :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "copy")
	text_input.input_buffer_select_all(&state.input)
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
	assert(
		text_input.input_buffer_string(&state.input) == "pasted",
		"expected Shift+Insert paste payload",
	)
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
		_send_mouse_sequence(&state, "\x1b[<65;2;2M"),
		"expected in-panel wheel-down to scroll history",
	)
	assert(state.historyScrollOffset == 0, "expected wheel-down to return to the history bottom")
	assert(
		!_send_mouse_sequence(&state, "\x1b[<64;2;7M"),
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
	text_input.input_buffer_push_text(&state.input, "abcdef")

	assert(
		_send_mouse_sequence(&state, "\x1b[<0;2;10M"),
		"expected input press to start selection",
	)
	assert(
		_send_mouse_sequence(&state, "\x1b[<32;4;10M"),
		"expected input drag to extend selection",
	)
	assert(
		_send_mouse_sequence(&state, "\x1b[<0;4;10m"),
		"expected input release to finish selection",
	)
	assert(
		text_input.input_buffer_selection_text(&state.input) == "abc",
		"expected dragged input text",
	)
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
		_send_mouse_sequence(&state, "\x1b[<0;2;2M"),
		"expected history press to start selection",
	)
	assert(
		_send_mouse_sequence(&state, "\x1b[<32;7;2M"),
		"expected history drag to extend selection",
	)
	assert(
		_send_mouse_sequence(&state, "\x1b[<0;7;2m"),
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
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "streamed entry"},
		) ==
		.None,
		"expected streamed text delta",
	)
	assert(app_poll_agent_host(&state), "expected streamed content to update history")
	assert(
		state.historyScrollOffset == 0,
		"expected streamed history text to return to the bottom",
	)
	assert(
		state.history[state.agentHost.historyIndex].cachedLineCount == 0,
		"expected streamed content to invalidate its wrapping cache",
	)
	_ = t
}

@(test)
test_thinking_spinner_hides_reasoning_and_yields_to_content :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID

	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Hidden reasoning", isThinking = true},
		) ==
		.None,
		"expected thinking delta to be accepted",
	)
	assert(app_poll_agent_host(&state), "expected thinking state to request a redraw")
	assert(state.agentHost.thinking, "expected host to track thinking state")
	assert(state.agentHost.spinnerVisible, "expected thinking state to show a spinner")
	assert(state.status == "Assistant thinking", "expected thinking status")

	state.historyRenderOnly = false
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Visible answer"},
		) ==
		.None,
		"expected text delta to be accepted",
	)
	assert(app_poll_agent_host(&state), "expected content delta to request a redraw")
	assert(
		state.history[state.agentHost.historyIndex].content == "Visible answer",
		"expected only normal content in assistant history",
	)
	assert(
		history_display_line(&state, state.agentHost.historyIndex, context.temp_allocator) ==
		"Visible answer",
		"expected normal content to replace the spinner",
	)
	_ = t
}

@(test)
test_thinking_spinner_invalidates_history_cache_and_clears :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append_history(&state, .Assistant, "")
	state.agentHost.historyIndex = len(state.history) - 1
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	_ = history_entry_line_count(&state, state.agentHost.historyIndex, 20)
	assert(
		state.history[state.agentHost.historyIndex].cachedLineCount > 0,
		"expected history line count to be cached",
	)

	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Hidden reasoning", isThinking = true},
		) ==
		.None,
		"expected thinking delta to be accepted",
	)
	assert(app_poll_agent_host(&state), "expected spinner visibility change to request a redraw")
	assert(
		state.history[state.agentHost.historyIndex].cachedLineCount == 0,
		"expected spinner visibility change to invalidate the wrapping cache",
	)
	state.agentHost.spinnerLastFrame = {}
	assert(app_poll_agent_host(&state), "expected elapsed spinner interval to request a redraw")
	assert(
		app_agent_host_spinner_frame(&state) == SPINNER_FRAMES[1],
		"expected elapsed spinner interval to advance to the next frame",
	)
	assert(
		agent.runtime_receive_stream_delta(
			&state.agentHost.runtime,
			agentID,
			ai.Chat_Stream_Delta{content = "Visible answer"},
		) ==
		.None,
		"expected text delta to clear thinking state",
	)
	assert(app_poll_agent_host(&state), "expected spinner state to clear")
	assert(
		app_agent_host_spinner_frame(&state) == "",
		"expected cleared stream state to hide the spinner",
	)
	_ = t
}

@(test)
test_chat_input_history_uses_up_down_arrows :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "first entry")
	app_submit_input(&state)
	text_input.input_buffer_push_text(&state.input, "second entry")
	app_submit_input(&state)
	text_input.input_buffer_push_text(&state.input, "draft")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'A'), "expected up arrow to recall newest history")
	assert(
		text_input.input_buffer_string(&state.input) == "second entry",
		"expected newest history entry",
	)
	assert(
		text_input.input_buffer_cursor_position(&state.input) == len("second entry"),
		"expected cursor at end",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'A'), "expected second up arrow to recall older history")
	assert(
		text_input.input_buffer_string(&state.input) == "first entry",
		"expected older history entry",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'B'), "expected down arrow to recall newer history")
	assert(
		text_input.input_buffer_string(&state.input) == "second entry",
		"expected newer history entry",
	)

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'B'), "expected down arrow to restore draft")
	assert(text_input.input_buffer_string(&state.input) == "draft", "expected draft restoration")
	_ = t
}

@(test)
test_shift_enter_inserts_newline_without_submitting :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "line one")
	// CSI-u encoding for shift+enter (functional code 13, modifier value 2 = shift).
	sequence := "\x1b[13;2u"
	handled := false
	for i := 0; i < len(sequence); i += 1 {
		handled = app_handle_input_byte(&state, sequence[i])
	}
	assert(handled, "expected shift+enter sequence to be handled")
	assert(
		text_input.input_buffer_string(&state.input) == "line one\n",
		"expected shift+enter to insert a newline instead of submitting",
	)
	assert(len(state.inputHistory) == 0, "expected shift+enter not to submit input")
	_ = t
}

@(test)
test_multiline_input_up_down_move_cursor_before_history :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "older entry")
	app_submit_input(&state)
	text_input.input_buffer_push_text(&state.input, "newer entry")
	app_submit_input(&state)

	text_input.input_buffer_push_text(&state.input, "line one\nline two\nline three")
	// Cursor sits on the middle line, at the 't' of "two".
	text_input.input_buffer_move_cursor_to(&state.input, len("line one\nline "))

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(app_handle_input_byte(&state, 'A'), "expected up arrow to move the cursor")
	assert(
		text_input.input_buffer_string(&state.input) == "line one\nline two\nline three",
		"expected up arrow off the first line to leave the buffer untouched",
	)
	assert(
		text_input.input_buffer_cursor_position(&state.input) == len("line "),
		"expected up arrow to preserve the column on the line above",
	)
	assert(state.inputHistoryCursor == -1, "expected history browsing to stay untouched")

	assert(!app_handle_input_byte(&state, 0x1b), "expected escape prefix to wait")
	assert(!app_handle_input_byte(&state, '['), "expected CSI prefix to wait")
	assert(
		app_handle_input_byte(&state, 'A'),
		"expected up arrow on the first line to fall back to history",
	)
	assert(
		text_input.input_buffer_string(&state.input) == "newer entry",
		"expected up arrow on the edge line to recall history",
	)
	_ = t
}

@(test)
test_kitty_key_release_does_not_repeat_action :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	text_input.input_buffer_push_text(&state.input, "line one\nline two\nline three")
	// Cursor sits on the middle line, at the 't' of "two".
	text_input.input_buffer_move_cursor_to(&state.input, len("line one\nline "))

	// Kitty CSI-u encoding for arrow-up: field 1 sub-value 1 = press.
	press := "\x1b[1;1:1A"
	for i := 0; i < len(press); i += 1 {
		_ = app_handle_input_byte(&state, press[i])
	}
	assert(
		text_input.input_buffer_cursor_position(&state.input) == len("line "),
		"expected the press event to move the cursor up one row",
	)

	// Same key, sub-value 3 = release; must not act again.
	release := "\x1b[1;1:3A"
	handled := false
	for i := 0; i < len(release); i += 1 {
		handled = app_handle_input_byte(&state, release[i])
	}
	assert(!handled, "expected key release to be ignored")
	assert(
		text_input.input_buffer_cursor_position(&state.input) == len("line "),
		"expected the release event not to move the cursor again",
	)
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
test_app_append_model_entry_infers_openai_embedding_capability_by_name :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	provider := settings.Provider_Config {
		name = "openai",
		type = .OpenAI,
	}

	app_append_model_entry(&state, provider, ai.Model{name = "gpt-test"}, context.allocator)
	app_append_model_entry(
		&state,
		provider,
		ai.Model{name = "text-embedding-3-small"},
		context.allocator,
	)

	assert(len(state.models) == 2, "expected two appended model entries")
	assert(state.models[0].supportsChat, "expected chat model name to support chat")
	assert(!state.models[0].supportsEmbeddings, "expected chat model name to reject embeddings")
	assert(!state.models[1].supportsChat, "expected embedding-named model to reject chat")
	assert(
		state.models[1].supportsEmbeddings,
		"expected embedding-named model to support embeddings",
	)
	_ = t
}

@(test)
test_safety_model_selection_requires_chat_capability :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone("ollama", context.allocator),
			providerType = .Ollama,
			model = strings.clone("embedding", context.allocator),
			supportsEmbeddings = true,
		},
	)

	app_select_config_safety_model(&state, 0)
	assert(
		state.config.safetyProvider == "",
		"expected rejected safety selection to keep provider",
	)
	assert(state.config.safetyModel == "", "expected rejected safety selection to keep model")
	assert(
		state.status == "Selected model does not support chat tools",
		"expected safety selection capability rejection",
	)
	_ = t
}

@(test)
test_safety_model_selection_accepts_chat_capability :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone("ollama", context.allocator),
			providerType = .Ollama,
			model = strings.clone("safety", context.allocator),
			supportsChat = true,
		},
	)

	app_select_config_safety_model(&state, 0)
	assert(state.config.safetyProvider == "ollama", "expected selected safety provider")
	assert(state.config.safetyModel == "safety", "expected selected safety model")
	assert(state.status == "Safety model selected and saved", "expected safety selection status")
	_ = t
}

@(test)
test_config_modal_formats_selected_model_options :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone("ollama", context.allocator),
			model = strings.clone("chat", context.allocator),
			supportsChat = true,
		},
	)
	setting := Config_Setting {
		id         = .Chat_Model,
		kind       = .Single_Select,
		modelIndex = 0,
	}
	state.config.selectedProvider = "ollama"
	state.config.selectedModel = "chat"

	assert(
		config_setting_line(&state, setting) == "* ollama / chat",
		"expected selected model option marker",
	)
	state.config.selectedModel = "other"
	assert(
		config_setting_line(&state, setting) == "  ollama / chat",
		"expected unselected model option marker",
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

	assert(app_has_overlay(&state, Config_Overlay), "expected config modal mode")
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
test_config_modal_formats_provider_control_rows :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.config.providers[0].apiKey = "secret-key"
	app_show_config(&state)

	assert(
		config_setting_line(&state, state.configSettings[0]) == "Provider: < ollama >",
		"expected provider choice row",
	)
	assert(
		config_setting_line(&state, state.configSettings[3]) == "Endpoint: http://localhost:11434",
		"expected provider value row",
	)
	assert(
		config_setting_line(&state, state.configSettings[4]) == "API key: ********",
		"expected masked provider API key row",
	)
	assert(
		config_setting_line(&state, state.configSettings[7]) == "[x] Enabled",
		"expected enabled checkbox row",
	)
	assert(
		config_setting_line(&state, state.configSettings[8]) == "[ Refresh models ]",
		"expected refresh button row",
	)
	_ = t
}

@(test)
test_config_provider_type_cycle_adds_openai_default_endpoint :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_cycle_config_provider_type(&state, 0)
	assert(state.config.providers[0].type == .OpenAI, "expected OpenAI provider type")
	assert(
		state.config.providers[0].endpoint == settings.DEFAULT_OPENAI_CONFIG_ENDPOINT,
		"expected OpenAI API base endpoint",
	)
	_ = t
}

@(test)
test_config_modal_settings_cursor_wraps :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings

	app_move_config_cursor(&state, -1)
	assert(
		state.configSettingCursor == len(state.configSettings) - 1,
		"expected settings cursor to wrap to final row",
	)
	app_move_config_cursor(&state, 1)
	assert(state.configSettingCursor == 0, "expected settings cursor to wrap to first row")
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
test_config_modal_renders_active_inline_text_focus :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings
	state.configSettingCursor = 1
	state.cursorBlinkOn = true

	assert(app_activate_config_setting(&state), "expected name text setting activation")
	sequence := render_app_frame_sequence(&state, 24, 100, context.temp_allocator)

	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[104mName: \x1b[0m"),
		"expected active inline field highlight",
	)
	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[106m \x1b[0m"),
		"expected active inline field cursor cell",
	)
	_ = t
}

@(test)
test_config_modal_keeps_active_field_focus_when_cursor_hidden :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings
	state.configSettingCursor = 1

	assert(app_activate_config_setting(&state), "expected name text setting activation")
	state.cursorBlinkOn = false
	sequence := render_app_frame_sequence(&state, 24, 100, context.temp_allocator)

	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[104mName: \x1b[0m"),
		"expected active inline field highlight to remain visible",
	)
	assert(
		!contains_string(sequence, "\x1b[0m\x1b[30m\x1b[106m \x1b[0m"),
		"expected active inline cursor cell to be hidden",
	)
	_ = t
}

@(test)
test_config_modal_renders_system_prompt_cursor :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)
	state.configSettingCursor = 3
	state.cursorBlinkOn = true

	assert(app_activate_config_setting(&state), "expected system prompt setting activation")
	widgets.text_editor_set_text(&state.configEditor, "first\nsecond")
	sequence := render_app_frame_sequence(&state, 24, 100, context.temp_allocator)

	assert(contains_string(sequence, "System prompt"), "expected system prompt editor heading")
	assert(contains_string(sequence, "first"), "expected first prompt line")
	assert(contains_string(sequence, "second"), "expected second prompt line")
	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[106m \x1b[0m"),
		"expected system prompt cursor cell",
	)
	_ = t
}

@(test)
test_inline_editable_viewport_keeps_unicode_cursor_visible :: proc(t: ^testing.T) {
	assert(
		inline_editable_viewport_start("abcdef", 6, 3) == 4,
		"expected viewport to reserve a cell for the cursor at the end",
	)
	assert(
		inline_editable_viewport_start("a\xc3\xa9bc", 4, 3) == 2,
		"expected viewport to preserve the multi-byte grapheme before the cursor",
	)
	_ = t
}

@(test)
test_config_modal_accepts_utf8_text_edit :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configFocus = .Settings
	state.configSettingCursor = 1

	assert(app_activate_config_setting(&state), "expected name text setting activation")
	assert(!app_handle_input_byte(&state, 0xc3), "expected UTF-8 prefix to wait")
	assert(app_handle_input_byte(&state, 0xa9), "expected UTF-8 sequence completion")
	assert(app_handle_input_byte(&state, '\r'), "expected name text commit")
	assert(
		state.config.providers[0].name == "ollama\xc3\xa9",
		"expected committed UTF-8 provider name",
	)
	_ = t
}

@(test)
test_config_modal_edits_tool_continuation_limit :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)

	assert(len(state.configSettings) == 5, "expected five advanced settings")
	assert(state.configSettings[1].id == .Tool_Continuations, "expected tool continuation setting")
	state.configSettingCursor = 1
	assert(app_activate_config_setting(&state), "expected continuation setting activation")
	assert(state.configEditing, "expected continuation setting edit mode")
	widgets.text_editor_set_text(&state.configEditor, "2500")
	app_commit_config_edit(&state)

	assert(state.config.toolContinuations == 2500, "expected continuation limit to update")
	assert(state.status == "Tool continuation limit saved", "expected saved continuation status")
	_ = t
}

@(test)
test_config_modal_rejects_invalid_tool_continuation_limit :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)
	state.configSettingCursor = 1
	app_activate_config_setting(&state)
	widgets.text_editor_set_text(&state.configEditor, "0")
	app_commit_config_edit(&state)

	assert(
		state.config.toolContinuations == settings.DEFAULT_TOOL_CONTINUATIONS,
		"expected invalid continuation limit to preserve previous value",
	)
	assert(
		state.status == "Tool continuation limit must be a positive integer",
		"expected invalid continuation status",
	)
	_ = t
}

@(test)
test_config_modal_cycles_approval_method :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)

	assert(state.configSettings[0].id == .Approval_Method, "expected approval method setting")
	assert(
		config_setting_line(&state, state.configSettings[0]) == "Approval method: < Always ask >",
		"expected initial approval method label",
	)
	assert(app_activate_config_setting(&state), "expected approval method activation")
	assert(
		app_has_overlay(&state, widgets.Dropdown_List),
		"expected approval method dropdown to open",
	)
	app_menu_overlay_move(&state, 1) // Always ask -> Approve SAFE
	app_menu_overlay_activate(&state)
	assert(state.config.approvalMethod == .Approve_Safe, "expected selected approval method")
	assert(state.status == "Approval method saved", "expected approval method save status")
	_ = t
}

@(test)
test_config_modal_edits_and_resets_system_prompt :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	app_show_config(&state)
	state.configCategory = .Advanced
	state.configFocus = .Settings
	app_rebuild_config_settings(&state)

	assert(state.configSettings[2].id == .System_Prompt_Mode, "expected prompt mode setting")
	assert(state.configSettings[3].id == .System_Prompt, "expected prompt setting")
	assert(state.configSettings[4].id == .Reset_System_Prompt, "expected prompt reset setting")
	assert(
		config_setting_line(&state, state.configSettings[3]) == "System prompt: Default",
		"expected compact default prompt summary",
	)

	state.configSettingCursor = 2
	assert(app_activate_config_setting(&state), "expected prompt mode activation")
	assert(state.config.systemPromptMode == .Replace, "expected prompt mode to cycle")

	state.configSettingCursor = 3
	assert(app_activate_config_setting(&state), "expected prompt editor activation")
	assert(state.configEditing, "expected prompt editor to open")
	assert(app_handle_input_byte(&state, 'a'), "expected prompt text input")
	assert(app_handle_input_byte(&state, '\r'), "expected prompt newline")
	assert(app_handle_input_byte(&state, 'b'), "expected prompt second line")
	assert(app_handle_input_byte(&state, widgets.CTRL_S), "expected prompt Ctrl-S save")
	assert(state.config.systemPrompt == "a\nb", "expected multiline prompt to save")
	assert(state.status == "System prompt saved", "expected prompt save status")

	state.configSettingCursor = 4
	assert(app_activate_config_setting(&state), "expected reset prompt activation")
	assert(state.config.systemPrompt == "", "expected reset prompt text")
	assert(state.config.systemPromptMode == .Append, "expected reset prompt mode")

	state.configSettingCursor = 3
	assert(app_activate_config_setting(&state), "expected empty prompt editor activation")
	assert(app_handle_input_byte(&state, widgets.CTRL_S), "expected empty prompt save")
	assert(state.config.systemPrompt == "", "expected empty prompt after save")
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
	state.agentHost.usage = ai.Chat_Usage {
		inputTokens    = 12500,
		hasInputTokens = true,
	}
	state.agentHost.contextWindowTokens = 32000

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
	text_input.input_buffer_push_text(&state.input, "hello\nthere")

	sequence := render_app_frame_sequence(&state, 12, 80, context.temp_allocator)
	assert(
		contains_string(sequence, console.clear_screen_home_sequence()),
		"expected full frame render to clear the screen",
	)
	assert(
		contains_string(sequence, INPUT_PANEL_TOP_RULE_AT_ROW_8),
		"expected input panel top rule",
	)
	assert(
		contains_string(sequence, "Mimir the terminal harness is ready."),
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

	assert(contains_string(sequence, "first line"), "expected first assistant line")
	assert(contains_string(sequence, "second line"), "expected later assistant lines")
	_ = t
}

@(test)
test_render_app_frame_draws_input_cursor_cell :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	text_input.input_buffer_push_text(&state.input, "ab")
	text_input.input_buffer_move_cursor_left(&state.input)
	state.cursorBlinkOn = true

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		contains_string(sequence, "a\x1b[0m\x1b[30m\x1b[106mb\x1b[0m"),
		"expected cursor cell to render with bright cyan background",
	)
	_ = t
}

@(test)
test_render_app_frame_draws_setup_input_cursor_cell :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.screen = .Setup
	text_input.input_buffer_push_text(&state.input, "ab")
	text_input.input_buffer_move_cursor_left(&state.input)
	state.cursorBlinkOn = true

	sequence := render_app_frame_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		contains_string(sequence, "a\x1b[0m\x1b[30m\x1b[106mb\x1b[0m"),
		"expected setup input cursor to render with bright cyan background",
	)
	_ = t
}

@(test)
test_render_app_frame_hides_input_cursor_while_config_editing :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	text_input.input_buffer_push_text(&state.input, "ab")
	text_input.input_buffer_move_cursor_left(&state.input)
	app_show_config(&state)
	state.configFocus = .Settings
	state.configSettingCursor = 1
	state.cursorBlinkOn = true

	assert(app_activate_config_setting(&state), "expected provider name editing to activate")
	sequence := render_app_frame_sequence(&state, 24, 100, context.temp_allocator)

	assert(
		!contains_string(sequence, "a\x1b[0m\x1b[30m\x1b[106mb\x1b[0m"),
		"expected inactive chat input cursor to be hidden",
	)
	assert(
		contains_string(sequence, "\x1b[0m\x1b[30m\x1b[106m \x1b[0m"),
		"expected active configuration editor cursor to remain visible",
	)
	_ = t
}

@(test)
test_render_app_input_panel_skips_screen_clear :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.status = "Testing"
	text_input.input_buffer_push_text(&state.input, "hello")

	sequence := render_app_input_panel_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		!contains_string(sequence, console.clear_screen_sequence()),
		"expected input-only render to avoid full screen clear",
	)
	assert(
		contains_string(sequence, INPUT_PANEL_TOP_RULE_AT_ROW_9),
		"expected input panel top rule",
	)
	assert(contains_string(sequence, "hello"), "expected input text")
	assert(
		!contains_string(sequence, HISTORY_PANEL_FIRST_ROW),
		"expected history panel to be untouched",
	)
	assert(!contains_string(sequence, "Testing"), "expected status bar to be untouched")
	_ = t
}

@(test)
test_render_app_history_panel_skips_screen_clear :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.status = "Testing"
	text_input.input_buffer_push_text(&state.input, "hello")

	sequence := render_app_history_panel_sequence(&state, 12, 40, context.temp_allocator)

	assert(
		!contains_string(sequence, console.clear_screen_sequence()),
		"expected history-only render to avoid full screen clear",
	)
	assert(
		contains_string(sequence, HISTORY_PANEL_FIRST_ROW),
		"expected history-only render to draw history",
	)
	assert(
		!contains_string(sequence, INPUT_PANEL_TOP_RULE_AT_ROW_9),
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
	text_input.input_buffer_push_text(&state.input, "ab")
	text_input.input_buffer_move_cursor_left(&state.input)
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
	text_input.input_buffer_push_text(&state.input, "cé")
	text_input.input_buffer_move_cursor_left(&state.input)
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
	text_input.input_buffer_push_text(&state.input, "alpha beta gamma")

	sequence := render_app_frame_sequence(&state, 10, 12, context.temp_allocator)

	assert(contains_string(sequence, "\x1b[6;1H─"), "expected wrapped input to grow panel")
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
		settings.config_path("/home/test", context.temp_allocator) ==
		"/home/test/.config/mimir/config.json",
		"expected config path under XDG-style user config directory",
	)
	assert(
		settings.global_skill_dir("/home/test", context.temp_allocator) ==
		"/home/test/.config/mimir/skills",
		"expected global skills under mimir config directory",
	)
	assert(
		settings.project_skill_dir("/repo", context.temp_allocator) == "/repo/.mimir/skills",
		"expected project skills under project .mimir directory",
	)
	assert(
		settings.skill_name_from_path("/repo/.mimir/skills/odin.md") == "odin",
		"expected skill name",
	)
	_ = t
}

@(test)
test_default_config_json_shape :: proc(t: ^testing.T) {
	config := settings.default_ollama_config(context.temp_allocator)
	defer {
		delete(config.providers)
		delete(config.contextWindows)
		delete(config.disabledSkills)
		delete(config.permissionGrants)
	}

	json := settings.config_to_json(config, context.temp_allocator)
	assert(json[:1] == "{", "expected config JSON object")
	assert(
		contains_string(json, "\"endpoint\": \"http://localhost:11434\""),
		"expected default config JSON to include Ollama endpoint",
	)
	assert(contains_string(json, "\"disabledSkills\": []"), "expected disabled skills config key")
	_ = t
}

@(test)
test_default_app_state_has_registries :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)

	assert(
		state.screen == .Chat && len(state.overlayStack) == 0,
		"expected app to start in chat mode",
	)
	assert(state.terminal.rows == 24, "expected default terminal rows")
	assert(state.terminal.columns == 80, "expected default terminal columns")
	assert(len(state.config.providers) == 1, "expected default Ollama provider")
	assert(
		state.config.providers[0].endpoint == settings.DEFAULT_CONFIG_ENDPOINT,
		"expected default endpoint",
	)
	_ = t
}

@(test)
test_app_init_with_missing_config_enters_setup_without_probe :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-app-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)

	assert(state.screen == .Setup, "expected missing config without probe to enter setup")
	assert(state.setupStep == .Endpoint, "expected setup to ask for endpoint first")
	assert(state.status == "Setup: enter Ollama endpoint", "expected setup status")
	_ = t
}

@(test)
test_app_init_with_saved_config_loads_chat_mode :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-app-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	config := settings.default_ollama_config(context.temp_allocator)
	config.selectedModel = "llama3.2"
	config.providers[0].model = "llama3.2"
	defer {
		delete(config.providers)
		delete(config.contextWindows)
		delete(config.disabledSkills)
		delete(config.permissionGrants)
	}
	assert(settings.save_config_to_file(home, config) == .None, "expected test config save")

	state := app_init_with_home(home, false, context.temp_allocator)
	defer app_destroy(&state)

	assert(
		state.screen == .Chat && len(state.overlayStack) == 0,
		"expected saved config to start in chat mode",
	)
	assert(state.config.selectedModel == "llama3.2", "expected saved selected model")
	assert(len(state.config.providers) == 1, "expected saved provider to load")
	assert(state.status == "Config loaded", "expected loaded config status")
	_ = t
}

@(test)
test_setup_endpoint_submission_prompts_for_api_key :: proc(t: ^testing.T) {
	state := app_init(context.temp_allocator)
	defer app_destroy(&state)
	state.screen = .Setup
	state.setupStep = .Endpoint

	text_input.input_buffer_push_text(&state.input, "http://localhost:11434")
	app_submit_input(&state)

	assert(state.screen == .Setup, "expected setup mode to continue")
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

// The history panel is borderless and the input panel draws only a top rule,
// so renders are identified by those cursor-positioned glyphs instead of titles.
HISTORY_PANEL_FIRST_ROW :: "\x1b[1;1H"
INPUT_PANEL_TOP_RULE_AT_ROW_8 :: "\x1b[8;1H─"
INPUT_PANEL_TOP_RULE_AT_ROW_9 :: "\x1b[9;1H─"

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
