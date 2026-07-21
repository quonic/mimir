package main

import "ai"
import "console"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

APP_POLL_INTERVAL_MS :: 25
APP_CURSOR_BLINK_INTERVAL :: 500 * time.Millisecond
HISTORY_WHEEL_SCROLL_ROWS :: 3

App_Mode :: enum int {
	Chat = 0,
	Config,
	Models,
	Setup,
	Approval,
}

Approval_Choice :: enum int {
	Allow_Once = 0,
	Allow_Session,
	Allow_Always,
	Deny,
}

Approval_Input_State :: enum int {
	Ready = 0,
	Escape,
	CSI,
}

Approval_State :: struct {
	call:          Tool_Call,
	callOwned:     bool,
	prepared:      Tool_Dispatch_Result,
	preparedOwned: bool,
	choice:        Approval_Choice,
	input:         Approval_Input_State,
}

App_Setup_Step :: enum int {
	Endpoint = 0,
	API_Key,
}

History_Role :: enum int {
	System = 0,
	User,
	Assistant,
	Tool,
}

History_Entry :: struct {
	role:            History_Role,
	content:         string,
	cachedLineWidth: int,
	cachedLineCount: int,
}

Model_Select_Entry :: struct {
	providerName: string,
	providerType: ai.Interface_Type,
	model:        string,
}

Model_Input_State :: enum int {
	Ready = 0,
	Escape,
	CSI,
}

Config_Category :: enum int {
	Providers = 0,
	Model_Selection,
}

Config_Focus :: enum int {
	Categories = 0,
	Settings,
}

Config_Input_State :: enum int {
	Ready = 0,
	Escape,
	CSI,
}

Config_Setting_Kind :: enum int {
	Checkbox = 0,
	Single_Select,
	Multi_Select,
	Text,
	Button,
}

Config_Setting_ID :: enum int {
	Provider = 0,
	Provider_Name,
	Provider_Type,
	Provider_Endpoint,
	Provider_API_Key,
	Provider_Model,
	Provider_Enabled,
	Refresh_Models,
	Add_Provider,
	Remove_Provider,
	Model,
}

Config_Setting :: struct {
	id:            Config_Setting_ID,
	kind:          Config_Setting_Kind,
	providerIndex: int,
	modelIndex:    int,
}

Input_Escape_State :: enum int {
	Ready = 0,
	Escape,
	CSI,
	CSI_Parameter,
	CSI_Mouse,
}

App_State :: struct {
	mode:                  App_Mode,
	input:                 Input_Buffer,
	inputEscape:           Input_Escape_State,
	inputEscapeParameter:  int,
	inputMouseSequence:    [256]byte,
	inputMouseSequenceLen: int,
	inputUTF8Pending:      [utf8.UTF_MAX]byte,
	inputUTF8PendingLen:   int,
	inputHistory:          [dynamic]string,
	inputHistoryCursor:    int,
	inputHistoryDraft:     string,
	cursorBlinkOn:         bool,
	status:                string,
	shouldQuit:            bool,
	terminal:              console.Terminal_Size,
	history:               [dynamic]History_Entry,
	historyScrollOffset:   int,
	historyRenderOnly:     bool,
	config:                Mimir_Config,
	configStringsOwned:    bool,
	configHome:            string,
	workingDirectory:      string,
	setupStep:             App_Setup_Step,
	setupEndpoint:         string,
	setupAPIKey:           string,
	tools:                 Tool_Registry,
	dispatcher:            Tool_Dispatcher,
	dispatcherReady:       bool,
	approval:              Approval_State,
	mcp:                   MCP_Registry,
	skills:                Skill_Registry,
	stream:                Assistant_Stream_State,
	models:                [dynamic]Model_Select_Entry,
	modelCursor:           int,
	modelInput:            Model_Input_State,
	modelProviderOwned:    bool,
	modelNameOwned:        bool,
	configCategory:        Config_Category,
	configFocus:           Config_Focus,
	configInput:           Config_Input_State,
	configSettings:        [dynamic]Config_Setting,
	configSettingCursor:   int,
	configProviderIndex:   int,
	configEdit:            Input_Buffer,
	configEditing:         bool,
	configEditingSetting:  Config_Setting,
	configUTF8Pending:     [utf8.UTF_MAX]byte,
	configUTF8PendingLen:  int,
}

app_init :: proc(allocator := context.allocator) -> App_State {
	return app_init_with_home("", false, allocator)
}

app_init_with_home :: proc(
	home: string,
	probeOllama: bool,
	allocator := context.allocator,
) -> App_State {
	state: App_State
	state.mode = .Chat
	state.stream.bufferAllocator = allocator
	state.stream.toolCalls = make([dynamic]ai.Tool_Call, 0, 0, allocator)
	state.input = input_buffer_init(allocator)
	state.inputHistory = make([dynamic]string, 0, 32, allocator)
	state.inputHistoryCursor = -1
	state.cursorBlinkOn = true
	state.status = "Ready"
	state.terminal = console.Terminal_Size {
		rows    = 24,
		columns = 80,
	}
	state.history = make([dynamic]History_Entry, 0, 32, allocator)
	state.configHome = strings.clone(home, context.allocator)
	workingDirectory, workingDirectoryErr := os.get_working_directory(context.allocator)
	if workingDirectoryErr == nil {
		state.workingDirectory = workingDirectory
	}
	ai.set_raw_http_log_home(state.configHome)
	state.config = default_ollama_config(allocator)
	app_bootstrap_config(&state, home, probeOllama, allocator)
	app_load_input_history(&state, allocator)
	state.tools = builtin_tool_registry(allocator)
	state.dispatcher, state.dispatcherReady = tool_dispatcher_init(
		state.workingDirectory,
		state.config.permissionGrants[:],
		allocator,
	)
	state.mcp = mcp_registry_from_config(state.config.mcpServers[:], allocator)
	state.skills = skill_registry_init(allocator)
	state.models = make([dynamic]Model_Select_Entry, 0, 16, allocator)
	state.configSettings = make([dynamic]Config_Setting, 0, 16, allocator)
	state.configEdit = input_buffer_init(allocator)
	append_history(&state, .System, "Mimir terminal harness ready.")
	return state
}

app_bootstrap_config :: proc(
	state: ^App_State,
	home: string,
	probeOllama: bool,
	allocator := context.allocator,
) {
	if home != "" {
		loaded, loadErr := load_config_from_file(home, allocator)
		switch loadErr {
		case .None:
			if state.configStringsOwned {
				config_destroy(&state.config)
			} else {
				delete(state.config.providers)
				delete(state.config.mcpServers)
				delete(state.config.skillPaths)
				delete(state.config.permissionGrants)
			}
			state.config = loaded
			state.configStringsOwned = true
			state.status = "Config loaded"
		case .Not_Found:
			if !probeOllama || !app_create_default_config_from_ollama(state, home, allocator) {
				app_enter_setup(state, "Setup: enter Ollama endpoint")
			}
		case .Invalid_JSON:
			app_enter_setup(state, "Setup: config could not be parsed")
		case .Invalid_Home, .Io_Error:
			app_enter_setup(state, "Setup: config could not be loaded")
		}
	}

	if state.mode == .Setup || (home == "" && !probeOllama) {
		ai.clear_interfaces()
		return
	}

	ai.clear_interfaces()
	registerResult := register_config_interfaces(
		state.config,
		probeOllama && state.mode != .Setup,
		allocator,
	)
	if state.mode != .Setup {
		app_select_first_available_model(state, allocator)
		if registerResult.ollamaProbeFailed {
			state.status = "Ollama unavailable; using saved config"
		}
	}
}

app_create_default_config_from_ollama :: proc(
	state: ^App_State,
	home: string,
	allocator := context.allocator,
) -> bool {
	models, err := ai.probe_ollama_endpoint(DEFAULT_CONFIG_ENDPOINT, allocator)
	if err != .None {
		return false
	}
	defer delete(models)

	if len(models) > 0 {
		state.config.selectedModel = strings.clone(models[0], allocator)
		state.config.providers[0].model = strings.clone(models[0], allocator)
	}

	if save_config_to_file(home, state.config) == .None {
		state.status = "Default Ollama config saved"
	} else {
		state.status = "Default Ollama config created; save failed"
	}
	return true
}

app_enter_setup :: proc(state: ^App_State, status: string) {
	state.mode = .Setup
	state.setupStep = .Endpoint
	state.status = status
}

app_destroy :: proc(state: ^App_State) {
	app_destroy_assistant_stream(state)
	input_buffer_destroy(&state.input)
	for entry in state.inputHistory {
		delete(entry)
	}
	delete(state.inputHistory)
	if state.inputHistoryDraft != "" {
		delete(state.inputHistoryDraft)
	}
	for entry in state.history {
		delete(entry.content)
	}
	delete(state.history)
	app_clear_approval(state)
	if state.dispatcherReady {
		tool_dispatcher_destroy(&state.dispatcher)
	}
	if state.configStringsOwned {
		config_destroy(&state.config)
	} else {
		for &provider in state.config.providers {
			provider_config_destroy(&provider, context.allocator)
		}
		delete(state.config.providers)
		delete(state.config.mcpServers)
		delete(state.config.skillPaths)
		delete(state.config.permissionGrants)
	}
	ai.set_raw_http_log_home("")
	delete(state.configHome)
	if state.workingDirectory != "" {
		delete(state.workingDirectory)
	}
	if state.setupEndpoint != "" {
		delete(state.setupEndpoint)
	}
	if state.setupAPIKey != "" {
		delete(state.setupAPIKey)
	}
	delete(state.tools.definitions)
	delete(state.mcp.servers)
	delete(state.skills.skills)
	if state.modelProviderOwned && state.config.selectedProvider != "" {
		delete(state.config.selectedProvider)
	}
	if state.modelNameOwned && state.config.selectedModel != "" {
		delete(state.config.selectedModel)
	}
	app_clear_model_entries(state)
	delete(state.configSettings)
	input_buffer_destroy(&state.configEdit)
	delete(state.models)
	ai.clear_interfaces()
}

run_app :: proc() {
	home, homeErr := os.user_home_dir(context.temp_allocator)
	state := app_init_with_home("", false)
	if homeErr == nil {
		app_destroy(&state)
		state = app_init_with_home(home, true)
	}
	defer app_destroy(&state)

	raw_state, raw_ok := console.enable_raw_input_mode()
	if !raw_ok {
		_, _ = console.write("Mimir requires an interactive terminal.\n")
		return
	}
	defer console.restore_raw_input_mode(&raw_state)

	_, _ = console.write(console.terminal_app_start_sequence())
	defer console.write(console.terminal_app_stop_sequence())
	_, _ = console.set_mouse_tracking_sgr(.Button, true)
	defer console.set_mouse_tracking_sgr(.Button, false)

	app_refresh_terminal_size(&state)
	render_app(&state)
	buffer: [1]byte
	lastCursorBlink := time.tick_now()
	for !state.shouldQuit {
		frameDirty := false
		historyDirty := false
		inputDirty := false
		input_ready, poll_ok := app_wait_for_input(APP_POLL_INTERVAL_MS)
		if !poll_ok {
			state.shouldQuit = true
			break
		}
		if input_ready {
			state.cursorBlinkOn = true
			lastCursorBlink = time.tick_now()
			count, err := os.read(os.stdin, buffer[:])
			if err != nil || count <= 0 {
				state.shouldQuit = true
				break
			}
			frameDirty = app_handle_input_byte(&state, buffer[0])
			if state.historyRenderOnly {
				historyDirty = true
				state.historyRenderOnly = false
				frameDirty = false
			}
		} else if app_flush_pending_input(&state) {
			frameDirty = true
		}
		if !input_ready && time.tick_since(lastCursorBlink) >= APP_CURSOR_BLINK_INTERVAL {
			state.cursorBlinkOn = !state.cursorBlinkOn
			lastCursorBlink = time.tick_now()
			inputDirty = true
		}
		if app_refresh_terminal_size(&state) {
			frameDirty = true
			historyDirty = false
		}
		if app_poll_assistant_stream(&state) {
			frameDirty = true
			if state.historyRenderOnly {
				historyDirty = true
				state.historyRenderOnly = false
				frameDirty = false
			}
		}
		if frameDirty {
			render_app(&state)
		} else if historyDirty {
			render_app_history_panel(&state)
		} else if inputDirty {
			render_app_input_panel(&state)
		}
		free_all(context.temp_allocator)
	}
}

render_app_input_panel :: proc(state: ^App_State) {
	sequence := render_app_input_panel_sequence(
		state,
		state.terminal.rows,
		state.terminal.columns,
		context.temp_allocator,
	)
	_, _ = console.write(console.synchronized_output_sequence(sequence, context.temp_allocator))
}

render_app_history_panel :: proc(state: ^App_State) {
	sequence := render_app_history_panel_sequence(
		state,
		state.terminal.rows,
		state.terminal.columns,
		context.temp_allocator,
	)
	_, _ = console.write(console.synchronized_output_sequence(sequence, context.temp_allocator))
}

app_wait_for_input :: proc(timeout_ms: int) -> (ready, ok: bool) {
	fds := [1]posix.pollfd{{fd = posix.FD(os.fd(os.stdin)), events = posix.Poll_Event{.IN}}}
	result := posix.poll(raw_data(fds[:]), posix.nfds_t(len(fds)), c.int(timeout_ms))
	if result < 0 {
		return false, false
	}
	if result == 0 {
		return false, true
	}
	return .IN in fds[0].revents, true
}

app_flush_pending_input :: proc(state: ^App_State) -> bool {
	if state.mode == .Models && state.modelInput == .Escape {
		app_cancel_model_selection(state)
		return true
	}
	if state.inputEscape != .Ready {
		app_reset_input_escape(state)
		return true
	}
	if state.inputUTF8PendingLen > 0 {
		app_reset_input_utf8_pending(state)
		return true
	}
	return false
}

append_history :: proc(state: ^App_State, role: History_Role, content: string) {
	append(
		&state.history,
		History_Entry{role = role, content = strings.clone(content, context.allocator)},
	)
	state.historyScrollOffset = 0
}

app_history_panel :: proc(state: ^App_State) -> console.Region {
	input_width := state.terminal.columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(input_buffer_string(&state.input), input_width)
	layout := compute_app_layout(state.terminal.rows, state.terminal.columns, input_lines)
	return console.panel_interior(console.Panel{region = layout.historyPanel})
}

app_scroll_history :: proc(state: ^App_State, rows: int) -> bool {
	if state.mode != .Chat || rows == 0 {
		return false
	}

	region := app_history_panel(state)
	maximum_offset :=
		history_line_count(state, console.region_width(region)) - console.region_height(region)
	if maximum_offset < 0 {
		maximum_offset = 0
	}

	previous_offset := state.historyScrollOffset
	state.historyScrollOffset += rows
	if state.historyScrollOffset < 0 {
		state.historyScrollOffset = 0
	} else if state.historyScrollOffset > maximum_offset {
		state.historyScrollOffset = maximum_offset
	}
	if state.historyScrollOffset == previous_offset {
		return false
	}

	state.historyRenderOnly = true
	return true
}

app_scroll_history_page :: proc(state: ^App_State, direction: int) -> bool {
	return app_scroll_history(state, direction * console.region_height(app_history_panel(state)))
}

app_handle_mouse_sequence :: proc(state: ^App_State, sequence: string) -> bool {
	event, event_err := console.parse_sgr_mouse_event_response(sequence)
	if event_err != .None || event.kind != .Wheel {
		return false
	}

	input_width := state.terminal.columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(input_buffer_string(&state.input), input_width)
	layout := compute_app_layout(state.terminal.rows, state.terminal.columns, input_lines)
	panel := layout.historyPanel
	if event.row < panel.top_row ||
	   event.row > panel.bottom_row ||
	   event.column < panel.left_column ||
	   event.column > panel.right_column {
		return false
	}

	switch event.button {
	case .Wheel_Up:
		return app_scroll_history(state, HISTORY_WHEEL_SCROLL_ROWS)
	case .Wheel_Down:
		return app_scroll_history(state, -HISTORY_WHEEL_SCROLL_ROWS)
	case .None, .Left, .Middle, .Right, .Wheel_Left, .Wheel_Right:
		return false
	}
	return false
}

app_handle_input_byte :: proc(state: ^App_State, input: byte) -> bool {
	if state.mode == .Approval {
		return app_handle_approval_input(state, input)
	}
	if state.mode == .Models {
		return app_handle_models_input(state, input)
	}
	if state.mode == .Config {
		return app_handle_config_input(state, input)
	}

	if state.inputEscape != .Ready {
		return app_handle_input_escape_byte(state, input)
	}

	switch input {
	case 1:
		app_reset_input_utf8_pending(state)
		input_buffer_move_cursor_start(&state.input)
		return true
	case 3, 4:
		app_reset_input_utf8_pending(state)
		state.shouldQuit = true
		state.status = "Exiting"
		return true
	case 5:
		app_reset_input_utf8_pending(state)
		input_buffer_move_cursor_end(&state.input)
		return true
	case 8, 127:
		app_reset_input_utf8_pending(state)
		app_reset_input_history_browse(state)
		return input_buffer_backspace(&state.input)
	case '\r':
		app_reset_input_utf8_pending(state)
		app_submit_input(state)
		return true
	case '\n':
		app_reset_input_utf8_pending(state)
		app_reset_input_history_browse(state)
		input_buffer_push_byte(&state.input, '\n')
		return true
	case 0x1b:
		app_reset_input_utf8_pending(state)
		state.inputEscapeParameter = 0
		state.inputEscape = .Escape
		return false
	case:
		if input >= 32 || input == '\t' {
			app_reset_input_history_browse(state)
			return app_handle_text_input_byte(state, input)
		}
	}
	return false
}

app_show_approval :: proc(state: ^App_State, call: Tool_Call) -> bool {
	if !state.dispatcherReady || state.mode == .Approval {
		return false
	}

	prepared := tool_dispatch_prepare(&state.dispatcher, call)
	if prepared.decision != .Approval_Required || !prepared.actionOK {
		tool_dispatch_result_destroy(&prepared, state.dispatcher.allocator)
		return false
	}

	app_clear_approval(state)
	state.approval.call = tool_call_clone(call, state.dispatcher.allocator)
	state.approval.callOwned = true
	state.approval.prepared = prepared
	state.approval.preparedOwned = true
	state.approval.choice = .Allow_Once
	state.approval.input = .Ready
	state.mode = .Approval
	state.status = "Permission approval required"
	return true
}

app_clear_approval :: proc(state: ^App_State) {
	if state.approval.callOwned {
		tool_call_destroy(&state.approval.call, state.dispatcher.allocator)
	}
	if state.approval.preparedOwned {
		tool_dispatch_result_destroy(&state.approval.prepared, state.dispatcher.allocator)
	}
	state.approval = {}
}

app_move_approval_choice :: proc(state: ^App_State, delta: int) {
	choice := int(state.approval.choice) + delta
	if choice < int(Approval_Choice.Allow_Once) {
		choice = int(Approval_Choice.Deny)
	} else if choice > int(Approval_Choice.Deny) {
		choice = int(Approval_Choice.Allow_Once)
	}
	state.approval.choice = Approval_Choice(choice)
}

app_handle_approval_input :: proc(state: ^App_State, input: byte) -> bool {
	switch state.approval.input {
	case .Escape:
		if input == '[' {
			state.approval.input = .CSI
			return false
		}
		app_apply_approval_choice(state, .Deny)
		return true
	case .CSI:
		state.approval.input = .Ready
		switch input {
		case 'A':
			app_move_approval_choice(state, -1)
			return true
		case 'B':
			app_move_approval_choice(state, 1)
			return true
		}
		return false
	case .Ready:
	}

	switch input {
	case 0x1b:
		state.approval.input = .Escape
		return false
	case 'j', 'J':
		app_move_approval_choice(state, 1)
		return true
	case 'k', 'K':
		app_move_approval_choice(state, -1)
		return true
	case '1':
		state.approval.choice = .Allow_Once
		return true
	case '2':
		state.approval.choice = .Allow_Session
		return true
	case '3':
		state.approval.choice = .Allow_Always
		return true
	case '4':
		state.approval.choice = .Deny
		return true
	case '\r':
		app_apply_approval_choice(state, state.approval.choice)
		return true
	case 3, 4:
		app_apply_approval_choice(state, .Deny)
		state.shouldQuit = true
		state.status = "Exiting"
		return true
	}
	return false
}

app_apply_approval_choice :: proc(state: ^App_State, choice: Approval_Choice) {
	if !state.approval.callOwned || !state.approval.preparedOwned {
		state.mode = .Chat
		return
	}

	if choice == .Deny {
		output := "Permission denied."
		append_history(state, .Tool, output)
		app_append_tool_result(state, state.approval.call.callID, output, true)
		state.status = "Tool call denied"
		state.mode = .Chat
		app_clear_approval(state)
		app_start_tool_continuation_if_ready(state)
		return
	}

	if choice == .Allow_Session || choice == .Allow_Always {
		grant, grantOK := tool_dispatch_grant_from_action(
			state.approval.prepared.action,
			state.dispatcher.allocator,
		)
		if !grantOK {
			state.status = "Tool call requires one-time approval"
			return
		}

		if choice == .Allow_Session {
			grantOK = tool_dispatcher_add_session_grant(&state.dispatcher, grant)
			permission_grant_destroy(&grant, state.dispatcher.allocator)
		} else {
			append(&state.config.permissionGrants, grant)
			state.dispatcher.persistentGrants = state.config.permissionGrants[:]
			if state.configHome != "" &&
			   save_config_to_file(state.configHome, state.config) != .None {
				grant = pop(&state.config.permissionGrants)
				permission_grant_destroy(&grant, state.dispatcher.allocator)
				state.dispatcher.persistentGrants = state.config.permissionGrants[:]
				state.status = "Permission grant could not be saved"
				return
			}
		}

		if !grantOK {
			state.status = "Permission grant could not be added"
			return
		}
	}

	output := tool_dispatch_execute_approved(&state.dispatcher, state.approval.call)
	append_history(state, .Tool, output)
	app_append_tool_result(state, state.approval.call.callID, output, false)
	state.status = "Tool call completed"
	state.mode = .Chat
	app_clear_approval(state)
	app_start_tool_continuation_if_ready(state)
}

app_handle_text_input_byte :: proc(state: ^App_State, input: byte) -> bool {
	if input < utf8.RUNE_SELF {
		app_reset_input_utf8_pending(state)
		input_buffer_push_byte(&state.input, input)
		return true
	}

	if state.inputUTF8PendingLen == 0 {
		if app_utf8_sequence_length(input) == 0 {
			return false
		}
		state.inputUTF8Pending[0] = input
		state.inputUTF8PendingLen = 1
	} else {
		if input < utf8.LOCB ||
		   input > utf8.HICB ||
		   state.inputUTF8PendingLen >= len(state.inputUTF8Pending) {
			app_reset_input_utf8_pending(state)
			return false
		}
		state.inputUTF8Pending[state.inputUTF8PendingLen] = input
		state.inputUTF8PendingLen += 1
	}

	expectedLength := app_utf8_sequence_length(state.inputUTF8Pending[0])
	if expectedLength == 0 {
		app_reset_input_utf8_pending(state)
		return false
	}
	if state.inputUTF8PendingLen < expectedLength {
		return false
	}

	_, width := utf8.decode_rune(state.inputUTF8Pending[:expectedLength])
	if width != expectedLength {
		app_reset_input_utf8_pending(state)
		return false
	}

	input_buffer_push_text(&state.input, string(state.inputUTF8Pending[:expectedLength]))
	app_reset_input_utf8_pending(state)
	return true
}

app_reset_input_utf8_pending :: proc(state: ^App_State) {
	state.inputUTF8PendingLen = 0
}

app_utf8_sequence_length :: proc(input: byte) -> int {
	switch {
	case input < utf8.RUNE_SELF:
		return 1
	case input >= 0xc2 && input <= 0xdf:
		return 2
	case input >= 0xe0 && input <= 0xef:
		return 3
	case input >= 0xf0 && input <= 0xf4:
		return 4
	}
	return 0
}

app_reset_input_escape :: proc(state: ^App_State) {
	state.inputEscape = .Ready
	state.inputEscapeParameter = 0
	state.inputMouseSequenceLen = 0
}

app_handle_input_escape_byte :: proc(state: ^App_State, input: byte) -> bool {
	switch state.inputEscape {
	case .Escape:
		if input == '[' {
			state.inputEscape = .CSI
			return false
		}
		app_reset_input_escape(state)
		return true
	case .CSI:
		switch input {
		case 'A':
			app_reset_input_escape(state)
			return app_input_history_previous(state)
		case 'B':
			app_reset_input_escape(state)
			return app_input_history_next(state)
		case 'C':
			app_reset_input_escape(state)
			return input_buffer_move_cursor_right(&state.input)
		case 'D':
			app_reset_input_escape(state)
			return input_buffer_move_cursor_left(&state.input)
		case 'H':
			app_reset_input_escape(state)
			input_buffer_move_cursor_start(&state.input)
			return true
		case 'F':
			app_reset_input_escape(state)
			input_buffer_move_cursor_end(&state.input)
			return true
		case '0' ..= '9':
			state.inputEscapeParameter = int(input - '0')
			state.inputEscape = .CSI_Parameter
			return false
		case '<':
			state.inputMouseSequence[0] = 0x1b
			state.inputMouseSequence[1] = '['
			state.inputMouseSequence[2] = '<'
			state.inputMouseSequenceLen = 3
			state.inputEscape = .CSI_Mouse
			return false
		case:
			app_reset_input_escape(state)
			return true
		}
	case .CSI_Parameter:
		switch input {
		case '0' ..= '9':
			if state.inputEscapeParameter > 999 {
				app_reset_input_escape(state)
				return true
			}
			state.inputEscapeParameter = state.inputEscapeParameter * 10 + int(input - '0')
			return false
		case '~':
			parameter := state.inputEscapeParameter
			app_reset_input_escape(state)
			switch parameter {
			case 5:
				return app_scroll_history_page(state, 1)
			case 6:
				return app_scroll_history_page(state, -1)
			case 1, 7:
				input_buffer_move_cursor_start(&state.input)
				return true
			case 3:
				return input_buffer_delete_at_cursor(&state.input)
			case 4, 8:
				input_buffer_move_cursor_end(&state.input)
				return true
			case:
				return true
			}
		case:
			app_reset_input_escape(state)
			return true
		}
	case .CSI_Mouse:
		if state.inputMouseSequenceLen >= len(state.inputMouseSequence) {
			app_reset_input_escape(state)
			return false
		}
		switch {
		case input >= '0' && input <= '9', input == ';':
			state.inputMouseSequence[state.inputMouseSequenceLen] = input
			state.inputMouseSequenceLen += 1
			return false
		case input == 'M' || input == 'm':
			state.inputMouseSequence[state.inputMouseSequenceLen] = input
			state.inputMouseSequenceLen += 1
			sequence := string(state.inputMouseSequence[:state.inputMouseSequenceLen])
			app_reset_input_escape(state)
			return app_handle_mouse_sequence(state, sequence)
		case:
			app_reset_input_escape(state)
			return false
		}
	case .Ready:
	}
	return false
}

app_record_input_history :: proc(state: ^App_State, text: string) {
	if text == "" {
		return
	}
	if len(state.inputHistory) > 0 && state.inputHistory[len(state.inputHistory) - 1] == text {
		app_reset_input_history_browse(state)
		return
	}
	append(&state.inputHistory, strings.clone(text, context.allocator))
	app_reset_input_history_browse(state)
	if state.configHome != "" && state.workingDirectory != "" {
		if save_input_history_to_file(
			   state.configHome,
			   state.workingDirectory,
			   state.inputHistory[:],
		   ) !=
		   .None {
			state.status = "Input history could not be saved"
		}
	}
}

app_load_input_history :: proc(state: ^App_State, allocator := context.allocator) {
	if state.configHome == "" || state.workingDirectory == "" {
		return
	}

	loaded, loadErr := load_input_history_from_file(
		state.configHome,
		state.workingDirectory,
		allocator,
	)
	if loadErr != .None {
		return
	}
	delete(state.inputHistory)
	state.inputHistory = loaded
}

app_clear_input_history :: proc(state: ^App_State) {
	for &entry in state.inputHistory {
		entry = ""
	}
	clear(&state.inputHistory)
	app_reset_input_history_browse(state)
	app_destroy_assistant_stream(state)
	for &entry in state.history {
		delete(entry.content)
		entry = {}
	}
	clear(&state.history)
	state.historyScrollOffset = 0

	if state.configHome == "" || state.workingDirectory == "" {
		state.status = "Input history cleared"
		return
	}
	if clear_input_history_file(state.configHome, state.workingDirectory) == .None {
		state.status = "Input history cleared"
	} else {
		state.status = "Input history could not be cleared"
	}
}

app_reset_input_history_browse :: proc(state: ^App_State) {
	state.inputHistoryCursor = -1
	if state.inputHistoryDraft != "" {
		delete(state.inputHistoryDraft)
		state.inputHistoryDraft = ""
	}
}

app_input_history_previous :: proc(state: ^App_State) -> bool {
	if len(state.inputHistory) == 0 {
		return false
	}

	if state.inputHistoryCursor < 0 {
		current := input_buffer_string(&state.input)
		if current != "" {
			state.inputHistoryDraft = strings.clone(current, context.allocator)
		}
		state.inputHistoryCursor = len(state.inputHistory) - 1
	} else if state.inputHistoryCursor > 0 {
		state.inputHistoryCursor -= 1
	}

	input_buffer_set_text(&state.input, state.inputHistory[state.inputHistoryCursor])
	input_buffer_move_cursor_end(&state.input)
	return true
}

app_input_history_next :: proc(state: ^App_State) -> bool {
	if state.inputHistoryCursor < 0 {
		return false
	}

	if state.inputHistoryCursor < len(state.inputHistory) - 1 {
		state.inputHistoryCursor += 1
		input_buffer_set_text(&state.input, state.inputHistory[state.inputHistoryCursor])
		input_buffer_move_cursor_end(&state.input)
		return true
	}

	input_buffer_set_text(&state.input, state.inputHistoryDraft)
	app_reset_input_history_browse(state)
	return true
}

app_submit_input :: proc(state: ^App_State) {
	text := input_buffer_submit(&state.input, context.allocator)
	defer delete(text)
	if state.mode == .Setup {
		app_submit_setup_input(state, text)
		return
	}

	if text == "" {
		state.status = "Ready"
		return
	}

	command := parse_slash_command(text)
	if command.isCommand {
		app_run_command(state, command)
		return
	}

	app_record_input_history(state, text)

	if app_assistant_stream_active(state) {
		state.status = "Assistant stream already active; use /stop first"
		return
	}

	app_clear_assistant_stream_conversation(&state.stream)
	append_history(state, .User, text)
	app_start_assistant_stream(state)
}

app_run_command :: proc(state: ^App_State, command: Parsed_Command) {
	switch command.kind {
	case .Exit:
		state.shouldQuit = true
		state.status = "Exiting"
	case .Config:
		app_show_config(state)
	case .Help:
		append_history(
			state,
			.Assistant,
			"Commands: /exit, /config, /help, /models, /skills, /stop, /clear",
		)
		state.status = "Help displayed"
	case .Models:
		app_show_models(state)
	case .Skills:
		state.status = "Skill discovery is not wired yet"
	case .Stop:
		app_cancel_assistant_stream(state)
	case .Clear:
		app_clear_input_history(state)
	case .Unknown:
		state.status = "Unknown command"
	case .None:
		state.status = "Ready"
	}
}

app_submit_setup_input :: proc(state: ^App_State, text: string) {
	switch state.setupStep {
	case .Endpoint:
		endpoint := text
		if endpoint == "" {
			endpoint = DEFAULT_CONFIG_ENDPOINT
		}
		if state.setupEndpoint != "" {
			delete(state.setupEndpoint)
		}
		state.setupEndpoint = strings.clone(endpoint, context.allocator)
		state.setupStep = .API_Key
		state.status = "Setup: enter optional API key, or press Enter"
	case .API_Key:
		if state.setupAPIKey != "" {
			delete(state.setupAPIKey)
		}
		state.setupAPIKey = strings.clone(text, context.allocator)
		app_complete_setup(state)
	}
}

app_complete_setup :: proc(state: ^App_State) {
	models, probeErr := ai.probe_ollama_endpoint(state.setupEndpoint, context.allocator)
	if probeErr != .None {
		state.setupStep = .Endpoint
		state.status = "Setup: Ollama unavailable; enter endpoint to retry"
		return
	}
	defer delete(models)

	delete(state.config.providers)
	delete(state.config.mcpServers)
	delete(state.config.skillPaths)
	delete(state.config.permissionGrants)
	state.config = default_ollama_config(context.allocator)
	state.config.providers[0].endpoint = strings.clone(state.setupEndpoint, context.allocator)
	state.config.providers[0].endpointOwned = true
	state.config.providers[0].apiKey = strings.clone(state.setupAPIKey, context.allocator)
	state.config.providers[0].apiKeyOwned = true
	if len(models) > 0 {
		state.config.selectedModel = strings.clone(models[0], context.allocator)
		state.config.providers[0].model = strings.clone(models[0], context.allocator)
		state.config.providers[0].modelOwned = true
	}

	ai.clear_interfaces()
	ai.add_interface_with_models(
		state.config.providers[0].name,
		state.config.providers[0].type,
		state.config.providers[0].endpoint,
		models[:],
	)

	delete(state.mcp.servers)
	state.mcp = mcp_registry_from_config(state.config.mcpServers[:], context.allocator)
	state.mode = .Chat
	if save_config_to_file(state.configHome, state.config) == .None {
		state.status = "Setup complete; config saved"
	} else {
		state.status = "Setup complete; config save failed"
	}
}

app_show_config :: proc(state: ^App_State) {
	if app_assistant_stream_active(state) {
		state.status = "Assistant stream active; use /stop before changing config"
		return
	}

	state.configCategory = .Providers
	state.configFocus = .Categories
	state.configInput = .Ready
	state.configSettingCursor = 0
	state.configProviderIndex = app_config_active_provider_index(state)
	state.configEditing = false
	input_buffer_clear(&state.configEdit)
	app_rebuild_config_settings(state)
	state.mode = .Config
	state.status = "Config: arrows/Tab, Enter, Esc"
}

app_rebuild_config_settings :: proc(state: ^App_State) {
	clear(&state.configSettings)
	switch state.configCategory {
	case .Providers:
		providerIndex := state.configProviderIndex
		if providerIndex < 0 || providerIndex >= len(state.config.providers) {
			providerIndex = app_config_active_provider_index(state)
			state.configProviderIndex = providerIndex
		}
		append(
			&state.configSettings,
			Config_Setting{id = .Provider, kind = .Single_Select, providerIndex = providerIndex},
		)
		if providerIndex >= 0 {
			append(
				&state.configSettings,
				Config_Setting{id = .Provider_Name, kind = .Text, providerIndex = providerIndex},
			)
			append(
				&state.configSettings,
				Config_Setting {
					id = .Provider_Type,
					kind = .Single_Select,
					providerIndex = providerIndex,
				},
			)
			append(
				&state.configSettings,
				Config_Setting {
					id = .Provider_Endpoint,
					kind = .Text,
					providerIndex = providerIndex,
				},
			)
			append(
				&state.configSettings,
				Config_Setting {
					id = .Provider_API_Key,
					kind = .Text,
					providerIndex = providerIndex,
				},
			)
			append(
				&state.configSettings,
				Config_Setting{id = .Provider_Model, kind = .Text, providerIndex = providerIndex},
			)
			append(
				&state.configSettings,
				Config_Setting {
					id = .Provider_Enabled,
					kind = .Checkbox,
					providerIndex = providerIndex,
				},
			)
		}
		append(
			&state.configSettings,
			Config_Setting{id = .Refresh_Models, kind = .Button, providerIndex = providerIndex},
		)
		append(
			&state.configSettings,
			Config_Setting{id = .Add_Provider, kind = .Button, providerIndex = providerIndex},
		)
		append(
			&state.configSettings,
			Config_Setting{id = .Remove_Provider, kind = .Button, providerIndex = providerIndex},
		)
	case .Model_Selection:
		app_rebuild_model_entries(state)
		for _, index in state.models {
			append(
				&state.configSettings,
				Config_Setting{id = .Model, kind = .Single_Select, modelIndex = index},
			)
		}
	}

	if state.configSettingCursor >= len(state.configSettings) {
		state.configSettingCursor = len(state.configSettings) - 1
	}
	if state.configSettingCursor < 0 {
		state.configSettingCursor = 0
	}
}

app_config_active_provider_index :: proc(state: ^App_State) -> int {
	for _, index in state.config.providers {
		if state.config.providers[index].name == state.config.selectedProvider {
			return index
		}
	}
	if len(state.config.providers) > 0 {
		return 0
	}
	return -1
}

app_handle_config_input :: proc(state: ^App_State, input: byte) -> bool {
	if state.configEditing {
		return app_handle_config_edit_input(state, input)
	}

	switch state.configInput {
	case .Escape:
		if input == '[' {
			state.configInput = .CSI
			return false
		}
		state.configInput = .Ready
		app_cancel_config(state)
		return true
	case .CSI:
		state.configInput = .Ready
		switch input {
		case 'A':
			app_move_config_cursor(state, -1)
			return true
		case 'B':
			app_move_config_cursor(state, 1)
			return true
		case 'C', 'D':
			app_toggle_config_focus(state)
			return true
		}
		return false
	case .Ready:
	}

	switch input {
	case 0x1b:
		state.configInput = .Escape
		return false
	case '\t':
		app_toggle_config_focus(state)
		return true
	case '\r':
		return app_activate_config_setting(state)
	case 3, 4:
		state.shouldQuit = true
		state.status = "Exiting"
		return true
	}
	return false
}

app_move_config_cursor :: proc(state: ^App_State, delta: int) {
	if state.configFocus == .Categories {
		category := int(state.configCategory) + delta
		if category < int(Config_Category.Providers) {
			category = int(Config_Category.Model_Selection)
		} else if category > int(Config_Category.Model_Selection) {
			category = int(Config_Category.Providers)
		}
		state.configCategory = Config_Category(category)
		state.configSettingCursor = 0
		app_rebuild_config_settings(state)
	} else if len(state.configSettings) > 0 {
		state.configSettingCursor += delta
		if state.configSettingCursor < 0 {
			state.configSettingCursor = len(state.configSettings) - 1
		} else if state.configSettingCursor >= len(state.configSettings) {
			state.configSettingCursor = 0
		}
	}
	state.status = "Config: arrows/Tab, Enter, Esc"
}

app_toggle_config_focus :: proc(state: ^App_State) {
	if state.configFocus == .Categories {
		state.configFocus = .Settings
	} else {
		state.configFocus = .Categories
	}
	state.status = "Config: arrows/Tab, Enter, Esc"
}

app_activate_config_setting :: proc(state: ^App_State) -> bool {
	if state.configFocus == .Categories {
		app_toggle_config_focus(state)
		return true
	}
	if len(state.configSettings) == 0 {
		return false
	}
	setting := state.configSettings[state.configSettingCursor]
	#partial switch setting.id {
	case .Provider:
		app_move_config_provider(state)
	case .Provider_Type:
		app_cycle_config_provider_type(state, setting.providerIndex)
	case .Provider_Enabled:
		if setting.providerIndex >= 0 && setting.providerIndex < len(state.config.providers) {
			state.config.providers[setting.providerIndex].enabled = !state.config.providers[setting.providerIndex].enabled
			app_apply_config_change(state, "Provider enabled setting saved")
		}
	case .Provider_Name, .Provider_Endpoint, .Provider_API_Key, .Provider_Model:
		app_begin_config_edit(state, setting)
	case .Refresh_Models:
		app_refresh_config_models(state, setting.providerIndex)
	case .Add_Provider:
		app_add_config_provider(state)
	case .Remove_Provider:
		app_remove_config_provider(state, setting.providerIndex)
	case .Model:
		app_select_config_model(state, setting.modelIndex)
	}
	return true
}

app_cancel_config :: proc(state: ^App_State) {
	state.mode = .Chat
	state.configInput = .Ready
	state.status = "Config closed"
}

app_move_config_provider :: proc(state: ^App_State) {
	if len(state.config.providers) == 0 {
		return
	}
	state.configProviderIndex += 1
	if state.configProviderIndex >= len(state.config.providers) {
		state.configProviderIndex = 0
	}
	state.configSettingCursor = 0
	app_rebuild_config_settings(state)
	state.status = "Provider selected for editing"
}

app_cycle_config_provider_type :: proc(state: ^App_State, providerIndex: int) {
	if providerIndex < 0 || providerIndex >= len(state.config.providers) {
		return
	}
	provider := &state.config.providers[providerIndex]
	switch provider.type {
	case .Ollama:
		provider.type = .OpenAI
	case .OpenAI:
		provider.type = .Anthropic
	case .Anthropic, .None:
		provider.type = .Ollama
	}
	app_apply_config_change(state, "Provider type saved")
}

app_begin_config_edit :: proc(state: ^App_State, setting: Config_Setting) {
	if setting.providerIndex < 0 || setting.providerIndex >= len(state.config.providers) {
		return
	}
	provider := state.config.providers[setting.providerIndex]
	value := ""
	#partial switch setting.id {
	case .Provider_Name:
		value = provider.name
	case .Provider_Endpoint:
		value = provider.endpoint
	case .Provider_API_Key:
		value = provider.apiKey
	case .Provider_Model:
		value = provider.model
	case:
		return
	}
	input_buffer_set_text(&state.configEdit, value)
	state.configEditingSetting = setting
	state.configEditing = true
	state.configUTF8PendingLen = 0
	state.status = "Editing: Enter saves, Esc cancels"
}

app_handle_config_edit_input :: proc(state: ^App_State, input: byte) -> bool {
	switch input {
	case 1:
		state.configUTF8PendingLen = 0
		input_buffer_move_cursor_start(&state.configEdit)
		return true
	case 5:
		state.configUTF8PendingLen = 0
		input_buffer_move_cursor_end(&state.configEdit)
		return true
	case 8, 127:
		state.configUTF8PendingLen = 0
		return input_buffer_backspace(&state.configEdit)
	case '\r':
		state.configUTF8PendingLen = 0
		app_commit_config_edit(state)
		return true
	case 0x1b:
		state.configEditing = false
		state.configUTF8PendingLen = 0
		input_buffer_clear(&state.configEdit)
		state.status = "Config edit canceled"
		return true
	case:
		if input >= 32 || input == '\t' {
			return app_handle_config_text_byte(state, input)
		}
	}
	return false
}

app_handle_config_text_byte :: proc(state: ^App_State, input: byte) -> bool {
	if input < utf8.RUNE_SELF {
		state.configUTF8PendingLen = 0
		input_buffer_push_byte(&state.configEdit, input)
		return true
	}

	if state.configUTF8PendingLen == 0 {
		if app_utf8_sequence_length(input) == 0 {
			return false
		}
		state.configUTF8Pending[0] = input
		state.configUTF8PendingLen = 1
	} else {
		if input < utf8.LOCB ||
		   input > utf8.HICB ||
		   state.configUTF8PendingLen >= len(state.configUTF8Pending) {
			state.configUTF8PendingLen = 0
			return false
		}
		state.configUTF8Pending[state.configUTF8PendingLen] = input
		state.configUTF8PendingLen += 1
	}

	expectedLength := app_utf8_sequence_length(state.configUTF8Pending[0])
	if state.configUTF8PendingLen < expectedLength {
		return false
	}
	_, width := utf8.decode_rune(state.configUTF8Pending[:expectedLength])
	if width != expectedLength {
		state.configUTF8PendingLen = 0
		return false
	}
	input_buffer_push_text(&state.configEdit, string(state.configUTF8Pending[:expectedLength]))
	state.configUTF8PendingLen = 0
	return true
}

app_commit_config_edit :: proc(state: ^App_State) {
	setting := state.configEditingSetting
	text := input_buffer_string(&state.configEdit)
	state.configEditing = false
	input_buffer_clear(&state.configEdit)

	if setting.providerIndex < 0 || setting.providerIndex >= len(state.config.providers) {
		state.status = "Provider no longer exists"
		return
	}
	if setting.id == .Provider_Name {
		if text == "" || app_config_provider_name_taken(state, text, setting.providerIndex) {
			state.status = "Provider name must be unique"
			return
		}
		oldName := state.config.providers[setting.providerIndex].name
		state.config.providers[setting.providerIndex].name = strings.clone(text, context.allocator)
		if state.config.providers[setting.providerIndex].nameOwned {
			delete(oldName, state.config.allocationAllocator)
		}
		state.config.providers[setting.providerIndex].nameOwned = true
		if state.config.selectedProvider == oldName {
			if state.modelProviderOwned && state.config.selectedProvider != "" {
				delete(state.config.selectedProvider)
			}
			state.config.selectedProvider = strings.clone(text, context.allocator)
			state.modelProviderOwned = true
		}
	} else if setting.id == .Provider_Endpoint {
		if state.config.providers[setting.providerIndex].endpointOwned {
			delete(
				state.config.providers[setting.providerIndex].endpoint,
				state.config.allocationAllocator,
			)
		}
		state.config.providers[setting.providerIndex].endpoint = strings.clone(
			text,
			context.allocator,
		)
		state.config.providers[setting.providerIndex].endpointOwned = true
	} else if setting.id == .Provider_API_Key {
		if state.config.providers[setting.providerIndex].apiKeyOwned {
			delete(
				state.config.providers[setting.providerIndex].apiKey,
				state.config.allocationAllocator,
			)
		}
		state.config.providers[setting.providerIndex].apiKey = strings.clone(
			text,
			context.allocator,
		)
		state.config.providers[setting.providerIndex].apiKeyOwned = true
	} else if setting.id == .Provider_Model {
		if state.config.providers[setting.providerIndex].modelOwned {
			delete(
				state.config.providers[setting.providerIndex].model,
				state.config.allocationAllocator,
			)
		}
		state.config.providers[setting.providerIndex].model = strings.clone(
			text,
			context.allocator,
		)
		state.config.providers[setting.providerIndex].modelOwned = true
		if state.config.providers[setting.providerIndex].name == state.config.selectedProvider {
			if state.modelNameOwned && state.config.selectedModel != "" {
				delete(state.config.selectedModel)
			}
			state.config.selectedModel = strings.clone(text, context.allocator)
			state.modelNameOwned = true
		}
	}
	app_apply_config_change(state, "Provider setting saved")
}

app_config_provider_name_taken :: proc(state: ^App_State, name: string, except: int) -> bool {
	for provider, index in state.config.providers {
		if index != except && provider.name == name {
			return true
		}
	}
	return false
}

app_add_config_provider :: proc(state: ^App_State) {
	name := "new-provider"
	if app_config_provider_name_taken(state, name, -1) {
		state.status = "Rename an existing provider before adding another"
		return
	}
	append(
		&state.config.providers,
		Provider_Config {
			name = strings.clone(name, context.allocator),
			type = .Ollama,
			endpoint = strings.clone(DEFAULT_CONFIG_ENDPOINT, context.allocator),
			nameOwned = true,
			endpointOwned = true,
		},
	)
	state.configProviderIndex = len(state.config.providers) - 1
	state.configSettingCursor = 0
	app_rebuild_config_settings(state)
	app_apply_config_change(state, "Provider added and saved")
}

app_remove_config_provider :: proc(state: ^App_State, providerIndex: int) {
	if providerIndex < 0 || providerIndex >= len(state.config.providers) {
		return
	}
	if len(state.config.providers) == 1 {
		state.status = "At least one provider is required"
		return
	}
	if state.config.providers[providerIndex].name == state.config.selectedProvider {
		state.status = "Choose another active model before removing this provider"
		return
	}
	provider_config_destroy(&state.config.providers[providerIndex], context.allocator)
	ordered_remove(&state.config.providers, providerIndex)
	if state.configProviderIndex >= len(state.config.providers) {
		state.configProviderIndex = len(state.config.providers) - 1
	}
	state.configSettingCursor = 0
	app_rebuild_config_settings(state)
	app_apply_config_change(state, "Provider removed and saved")
}

app_refresh_config_models :: proc(state: ^App_State, providerIndex: int) {
	if providerIndex < 0 || providerIndex >= len(state.config.providers) {
		return
	}
	provider := state.config.providers[providerIndex]
	if provider.type != .Ollama {
		state.status = "Only Ollama providers support refresh"
		return
	}
	models, err := ai.probe_ollama_endpoint(provider.endpoint, context.allocator)
	if err != .None {
		state.status = "Provider model refresh failed"
		return
	}
	defer delete(models)
	ai.clear_interfaces()
	for configuredProvider in state.config.providers {
		if !configuredProvider.enabled {
			continue
		}
		if configuredProvider.name == provider.name {
			ai.add_interface_with_models(
				configuredProvider.name,
				configuredProvider.type,
				configuredProvider.endpoint,
				models[:],
			)
		} else {
			ai.add_interface(
				configuredProvider.name,
				configuredProvider.type,
				configuredProvider.endpoint,
			)
		}
	}
	app_rebuild_config_settings(state)
	state.status = "Provider models refreshed"
}

app_select_config_model :: proc(state: ^App_State, modelIndex: int) {
	if modelIndex < 0 || modelIndex >= len(state.models) {
		return
	}
	entry := state.models[modelIndex]
	if state.modelProviderOwned && state.config.selectedProvider != "" {
		delete(state.config.selectedProvider)
	}
	if state.modelNameOwned && state.config.selectedModel != "" {
		delete(state.config.selectedModel)
	}
	state.config.selectedProvider = strings.clone(entry.providerName, context.allocator)
	state.config.selectedModel = strings.clone(entry.model, context.allocator)
	state.modelProviderOwned = true
	state.modelNameOwned = true
	for &provider in state.config.providers {
		if provider.name == entry.providerName {
			if provider.modelOwned && provider.model != "" {
				delete(provider.model, context.allocator)
			}
			provider.model = strings.clone(entry.model, context.allocator)
			provider.modelOwned = true
			break
		}
	}
	app_apply_config_change(state, "Model selected and saved")
}

app_apply_config_change :: proc(state: ^App_State, successStatus: string) {
	ai.clear_interfaces()
	register_config_interfaces(state.config, false)
	app_rebuild_model_entries(state)
	if state.configHome != "" && save_config_to_file(state.configHome, state.config) != .None {
		state.status = "Config changed; save failed"
		return
	}
	state.status = successStatus
}

app_show_models :: proc(state: ^App_State) {
	if app_assistant_stream_active(state) {
		state.status = "Assistant stream active; use /stop before changing models"
		return
	}

	app_rebuild_model_entries(state, context.allocator)
	if len(state.models) == 0 {
		state.mode = .Chat
		state.status = "No models found"
		return
	}

	state.modelCursor = app_current_model_index(state)
	state.modelInput = .Ready
	state.mode = .Models
	state.status = "Select model: arrows/j/k, Enter, Esc"
}

app_clear_model_entries :: proc(state: ^App_State) {
	for entry in state.models {
		delete(entry.providerName)
		delete(entry.model)
	}
	clear(&state.models)
	state.modelCursor = 0
	state.modelInput = .Ready
}

app_rebuild_model_entries :: proc(state: ^App_State, allocator := context.allocator) {
	app_clear_model_entries(state)
	for provider in state.config.providers {
		if !provider.enabled {
			continue
		}

		added := false
		if iface, ok := ai.get_interface(provider.name); ok && len(iface.models) > 0 {
			for model in iface.models {
				app_append_model_entry(state, provider, model, allocator)
			}
			added = true
		}

		if !added && provider.type == .Ollama {
			models, err := ai.probe_ollama_endpoint(provider.endpoint, allocator)
			if err == .None {
				for model in models {
					app_append_model_entry(state, provider, model, allocator)
				}
				added = len(models) > 0
				delete(models)
			}
		}

		if !added && provider.model != "" {
			app_append_model_entry(state, provider, provider.model, allocator)
		}
	}
}

app_append_model_entry :: proc(
	state: ^App_State,
	provider: Provider_Config,
	model: string,
	allocator := context.allocator,
) {
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone(provider.name, allocator),
			providerType = provider.type,
			model = strings.clone(model, allocator),
		},
	)
}

app_current_model_index :: proc(state: ^App_State) -> int {
	for entry, index in state.models {
		if entry.providerName == state.config.selectedProvider &&
		   entry.model == state.config.selectedModel {
			return index
		}
	}
	return 0
}

app_handle_models_input :: proc(state: ^App_State, input: byte) -> bool {
	switch state.modelInput {
	case .Escape:
		if input == '[' {
			state.modelInput = .CSI
			return false
		}
		state.modelInput = .Ready
		app_cancel_model_selection(state)
		return true
	case .CSI:
		state.modelInput = .Ready
		switch input {
		case 'A':
			app_move_model_cursor(state, -1)
			return true
		case 'B':
			app_move_model_cursor(state, 1)
			return true
		case:
			return false
		}
	case .Ready:
	}

	switch input {
	case 0x1b:
		state.modelInput = .Escape
		return false
	case 'j', 'J':
		app_move_model_cursor(state, 1)
		return true
	case 'k', 'K':
		app_move_model_cursor(state, -1)
		return true
	case '\r':
		app_select_model_entry(state)
		return true
	case 3, 4:
		state.shouldQuit = true
		state.status = "Exiting"
		return true
	}
	return false
}

app_move_model_cursor :: proc(state: ^App_State, delta: int) {
	if len(state.models) == 0 {
		state.modelCursor = 0
		return
	}

	state.modelCursor += delta
	if state.modelCursor < 0 {
		state.modelCursor = len(state.models) - 1
	} else if state.modelCursor >= len(state.models) {
		state.modelCursor = 0
	}
	state.status = "Select model: arrows/j/k, Enter, Esc"
}

app_cancel_model_selection :: proc(state: ^App_State) {
	state.mode = .Chat
	state.modelInput = .Ready
	state.status = "Model selection canceled"
}

app_select_model_entry :: proc(state: ^App_State) {
	if len(state.models) == 0 || state.modelCursor < 0 || state.modelCursor >= len(state.models) {
		state.mode = .Chat
		state.status = "No model selected"
		return
	}

	entry := state.models[state.modelCursor]
	if state.modelProviderOwned && state.config.selectedProvider != "" {
		delete(state.config.selectedProvider)
	}
	if state.modelNameOwned && state.config.selectedModel != "" {
		delete(state.config.selectedModel)
	}
	state.config.selectedProvider = strings.clone(entry.providerName, context.allocator)
	state.config.selectedModel = strings.clone(entry.model, context.allocator)
	state.modelProviderOwned = true
	state.modelNameOwned = true

	for &provider in state.config.providers {
		if provider.name == entry.providerName {
			if provider.modelOwned && provider.model != "" {
				delete(provider.model, context.allocator)
			}
			provider.model = strings.clone(entry.model, context.allocator)
			provider.modelOwned = true
			break
		}
	}

	state.mode = .Chat
	state.modelInput = .Ready
	if state.configHome != "" {
		if save_config_to_file(state.configHome, state.config) == .None {
			state.status = "Model selected and saved"
		} else {
			state.status = "Model selected; config save failed"
		}
		return
	}
	state.status = "Model selected"
}

app_find_provider :: proc(config: Mimir_Config, name: string) -> (Provider_Config, bool) {
	for provider in config.providers {
		if provider.name == name {
			return provider, true
		}
	}
	return Provider_Config{}, false
}

app_model_list_text :: proc(models: []string, allocator := context.allocator) -> string {
	if len(models) == 0 {
		return "No models found."
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, "Models:")
	for model in models {
		strings.write_string(&builder, "\n- ")
		strings.write_string(&builder, model)
	}
	return strings.to_string(builder)
}

app_select_first_available_model :: proc(state: ^App_State, allocator := context.allocator) {
	if state.config.selectedModel != "" || state.config.selectedProvider == "" {
		return
	}

	iface, ok := ai.get_interface(state.config.selectedProvider)
	if !ok || len(iface.models) == 0 {
		return
	}

	state.config.selectedModel = strings.clone(iface.models[0], allocator)
	for &provider in state.config.providers {
		if provider.name == state.config.selectedProvider && provider.model == "" {
			provider.model = strings.clone(iface.models[0], allocator)
			return
		}
	}
}

render_app :: proc(state: ^App_State) {
	sequence := render_app_frame_sequence(
		state,
		state.terminal.rows,
		state.terminal.columns,
		context.temp_allocator,
	)
	_, _ = console.write(console.synchronized_output_sequence(sequence, context.temp_allocator))
}

app_refresh_terminal_size :: proc(state: ^App_State) -> bool {
	return app_set_terminal_size(state, app_terminal_size())
}

app_set_terminal_size :: proc(state: ^App_State, size: console.Terminal_Size) -> bool {
	if size.rows == state.terminal.rows && size.columns == state.terminal.columns {
		return false
	}
	state.terminal = size
	return true
}

app_terminal_size :: proc() -> console.Terminal_Size {
	if size, ok := console.terminal_size(); ok {
		return size
	}
	return console.Terminal_Size {
		rows = app_terminal_dimension("LINES", 24),
		columns = app_terminal_dimension("COLUMNS", 80),
	}
}

app_terminal_dimension :: proc(name: string, fallback: int) -> int {
	value := os.get_env(name, context.temp_allocator)
	parsed, ok := strconv.parse_int(value)
	if ok && parsed > 0 {
		return parsed
	}
	return fallback
}
