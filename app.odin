#+vet explicit-allocators
package main

import "agent"
import "ai"
import "approval_safety"
import "code_index"
import "commands"
import "console"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "input_history"
import "settings"
import "text_input"
import "tool_policy"
import "widgets"

APP_POLL_INTERVAL_MS :: 25
APP_CURSOR_BLINK_INTERVAL :: 500 * time.Millisecond
HISTORY_WHEEL_SCROLL_ROWS :: 3

App_Mode :: enum int {
	Chat = 0,
	Config,
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
	CSI_Mouse,
}

Approval_State :: struct {
	call:           tool_policy.Tool_Call,
	callOwned:      bool,
	prepared:       tool_policy.Tool_Dispatch_Result,
	preparedOwned:  bool,
	historyIndex:   int,
	agentID:        agent.Agent_ID,
	agentRequestID: string,
	safety:         approval_safety.State,
	choice:         Approval_Choice,
	input:          Approval_Input_State,
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

Mouse_Selection_Panel :: enum int {
	None = 0,
	Input,
	History,
}

History_Selection :: struct {
	anchorLine:   int,
	anchorColumn: int,
	line:         int,
	column:       int,
}

History_Entry :: struct {
	role:            History_Role,
	content:         string,
	cachedLineWidth: int,
	cachedLineCount: int,
}

Model_Select_Entry :: struct {
	providerName:       string,
	providerType:       ai.Interface_Type,
	model:              string,
	supportsChat:       bool,
	supportsEmbeddings: bool,
}

Config_Category :: enum int {
	Providers = 0,
	Chat_Model,
	Embedding_Model,
	Safety_Model,
	Advanced,
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
	Provider_Context_Window,
	Provider_Enabled,
	Refresh_Models,
	Add_Provider,
	Remove_Provider,
	Chat_Model,
	Embedding_Model,
	Safety_Model,
	Approval_Method,
	Tool_Continuations,
	System_Prompt_Mode,
	System_Prompt,
	Reset_System_Prompt,
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
	CSI_Modifier,
	CSI_Mouse,
	Paste,
}

App_State :: struct {
	allocator:              mem.Allocator,
	mode:                   App_Mode,
	input:                  text_input.Input_Buffer,
	inputEscape:            Input_Escape_State,
	inputEscapeParameter:   int,
	inputEscapeModifier:    int,
	inputMouseSequence:     [256]byte,
	inputMouseSequenceLen:  int,
	inputPaste:             [dynamic]byte,
	inputUTF8Pending:       [utf8.UTF_MAX]byte,
	inputUTF8PendingLen:    int,
	inputHistory:           [dynamic]string,
	inputHistoryCursor:     int,
	inputHistoryDraft:      string,
	cursorBlinkOn:          bool,
	status:                 string,
	shouldQuit:             bool,
	terminal:               console.Terminal_Size,
	history:                [dynamic]History_Entry,
	historyScrollOffset:    int,
	historyRenderOnly:      bool,
	mouseSelectionPanel:    Mouse_Selection_Panel,
	historySelection:       History_Selection,
	config:                 settings.Mimir_Config,
	configStringsOwned:     bool,
	configHome:             string,
	workingDirectory:       string,
	setupStep:              App_Setup_Step,
	setupEndpoint:          string,
	setupAPIKey:            string,
	dispatcher:             tool_policy.Tool_Dispatcher,
	dispatcherReady:        bool,
	approval:               Approval_State,
	mcp:                    settings.MCP_Registry,
	skills:                 settings.Skill_Registry,
	codeIndex:              code_index.Code_Index,
	codeIndexReady:         bool,
	agentHost:              Agent_Host,
	toolExecution:          Tool_Execution_State,
	models:                 [dynamic]Model_Select_Entry,
	modelProviderOwned:     bool,
	modelNameOwned:         bool,
	embeddingProviderOwned: bool,
	embeddingModelOwned:    bool,
	safetyProviderOwned:    bool,
	safetyModelOwned:       bool,
	configCategory:         Config_Category,
	configFocus:            Config_Focus,
	configInput:            Config_Input_State,
	configSettings:         [dynamic]Config_Setting,
	configSettingCursor:    int,
	configProviderIndex:    int,
	configEditor:           widgets.Text_Editor,
	configEditing:          bool,
	configEditingSetting:   Config_Setting,
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
	state.allocator = allocator
	state.mode = .Chat
	state.agentHost = agent_host_init(allocator)
	state.toolExecution.allocator = allocator
	state.toolExecution.historyIndex = -1
	state.input = text_input.input_buffer_init(allocator)
	state.inputPaste = make([dynamic]byte, 0, 0, allocator)
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
	state.config = settings.default_ollama_config(allocator)
	app_bootstrap_config(&state, home, probeOllama, allocator)
	app_load_input_history(&state, allocator)
	app_rebuild_code_index(&state, allocator)
	state.dispatcher, state.dispatcherReady = tool_policy.tool_dispatcher_init(
		state.workingDirectory,
		state.config.permissionGrants[:],
		allocator,
	)
	state.mcp = settings.mcp_registry_from_config(state.config.mcpServers[:], allocator)
	state.skills = settings.skill_registry_init(allocator)
	state.models = make([dynamic]Model_Select_Entry, 0, 16, allocator)
	state.configSettings = make([dynamic]Config_Setting, 0, 16, allocator)
	state.configEditor = widgets.text_editor_init(allocator)
	append_history(&state, .System, "Mimir the terminal harness is ready.")
	return state
}

app_bootstrap_config :: proc(
	state: ^App_State,
	home: string,
	probeOllama: bool,
	allocator := context.allocator,
) {
	if home != "" {
		loaded, loadErr := settings.load_config_from_file(home, allocator)
		switch loadErr {
		case .None:
			if state.configStringsOwned {
				settings.config_destroy(&state.config)
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
	registerResult := app_register_config_interfaces(
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
	models, err := ai.probe_ollama_endpoint(settings.DEFAULT_CONFIG_ENDPOINT, allocator)
	if err != .None {
		return false
	}
	defer ai.models_destroy(&models, allocator)

	if len(models) > 0 {
		for model in models {
			if !ai.model_supports_chat(model) {
				continue
			}
			state.config.selectedModel = strings.clone(model.name, allocator)
			state.modelNameOwned = true
			state.config.providers[0].model = strings.clone(model.name, allocator)
			state.config.providers[0].modelOwned = true
			break
		}
	}

	if settings.save_config_to_file(home, state.config) == .None {
		state.status = "Default Ollama config saved"
	} else {
		state.status = "Default Ollama config created; save failed"
	}
	return true
}

Config_Register_Result :: struct {
	ollamaProbeFailed: bool,
	modelCount:        int,
}

app_register_config_interfaces :: proc(
	config: settings.Mimir_Config,
	probeOllama := false,
	allocator := context.allocator,
) -> Config_Register_Result {
	result: Config_Register_Result
	for provider in config.providers {
		if !provider.enabled {
			continue
		}
		if probeOllama && provider.type == .Ollama {
			models, err := ai.probe_ollama_endpoint(provider.endpoint, allocator)
			if err == .None {
				result.modelCount += len(models)
				ai.add_interface_with_models(
					provider.name,
					provider.type,
					provider.endpoint,
					models[:],
				)
				ai.models_destroy(&models, allocator)
				continue
			}
			result.ollamaProbeFailed = true
		}
		ai.add_interface(provider.name, provider.type, provider.endpoint)
	}
	return result
}

app_enter_setup :: proc(state: ^App_State, status: string) {
	state.mode = .Setup
	state.setupStep = .Endpoint
	state.status = status
}

app_destroy :: proc(state: ^App_State) {
	agent_host_destroy(&state.agentHost)
	app_destroy_tool_execution(&state.toolExecution)
	text_input.input_buffer_destroy(&state.input)
	delete(state.inputPaste)
	for entry in state.inputHistory {
		delete(entry, state.allocator)
	}
	delete(state.inputHistory)
	if state.inputHistoryDraft != "" {
		delete(state.inputHistoryDraft, state.allocator)
	}
	for entry in state.history {
		delete(entry.content, context.allocator)
	}
	delete(state.history)
	app_clear_approval(state)
	if state.dispatcherReady {
		tool_policy.tool_dispatcher_destroy(&state.dispatcher)
	}
	if state.codeIndexReady {
		code_index.code_index_destroy(&state.codeIndex, context.allocator)
	}
	if state.configStringsOwned {
		settings.config_destroy(&state.config)
	} else {
		for &provider in state.config.providers {
			settings.provider_config_destroy(&provider, context.allocator)
		}
		delete(state.config.providers)
		for &entry in state.config.contextWindows {
			if entry.providerName != "" {
				delete(entry.providerName, context.allocator)
			}
			if entry.model != "" {
				delete(entry.model, context.allocator)
			}
		}
		delete(state.config.contextWindows)
		delete(state.config.mcpServers)
		delete(state.config.skillPaths)
		delete(state.config.permissionGrants)
	}
	ai.set_raw_http_log_home("")
	delete(state.configHome, context.allocator)
	if state.workingDirectory != "" {
		delete(state.workingDirectory, context.allocator)
	}
	if state.setupEndpoint != "" {
		delete(state.setupEndpoint, context.allocator)
	}
	if state.setupAPIKey != "" {
		delete(state.setupAPIKey, context.allocator)
	}
	delete(state.mcp.servers)
	delete(state.skills.skills)
	if !state.configStringsOwned {
		if state.modelProviderOwned && state.config.selectedProvider != "" {
			delete(state.config.selectedProvider, context.allocator)
		}
		if state.modelNameOwned && state.config.selectedModel != "" {
			delete(state.config.selectedModel, context.allocator)
		}
		if state.embeddingProviderOwned && state.config.embeddingProvider != "" {
			delete(state.config.embeddingProvider, context.allocator)
		}
		if state.embeddingModelOwned && state.config.embeddingModel != "" {
			delete(state.config.embeddingModel, context.allocator)
		}
		if state.safetyProviderOwned && state.config.safetyProvider != "" {
			delete(state.config.safetyProvider, context.allocator)
		}
		if state.safetyModelOwned && state.config.safetyModel != "" {
			delete(state.config.safetyModel, context.allocator)
		}
	}
	app_clear_model_entries(state)
	delete(state.configSettings)
	widgets.text_editor_destroy(&state.configEditor)
	delete(state.models)
	ai.clear_interfaces()
}

run_app :: proc() {
	home, homeErr := os.user_home_dir(context.temp_allocator)
	state := app_init_with_home("", false, context.allocator)
	if homeErr == nil {
		app_destroy(&state)
		state = app_init_with_home(home, true, context.allocator)
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
	_, _ = console.set_mouse_tracking_sgr(.Drag, true)
	defer console.set_mouse_tracking_sgr(.Drag, false)
	_, _ = console.set_bracketed_paste_mode(true)
	defer console.set_bracketed_paste_mode(false)

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
			if state.mode == .Config && state.configEditing {
				frameDirty = true
			} else if state.mode == .Chat || state.mode == .Setup {
				inputDirty = true
			}
		}
		if app_refresh_terminal_size(&state) {
			frameDirty = true
			historyDirty = false
		}
		if app_poll_tool_execution(&state) {
			frameDirty = true
		}
		if app_poll_agent_host(&state) {
			frameDirty = true
			if state.historyRenderOnly {
				historyDirty = true
				state.historyRenderOnly = false
				frameDirty = false
			}
		}
		if state.mode == .Approval && app_poll_approval_safety(&state) {
			_ = app_apply_approval_method(&state)
			frameDirty = true
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
	if state.inputEscape == .Paste {
		app_reset_input_paste(state)
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
	state.historySelection = {}
}

app_tool_history_content :: proc(call: tool_policy.Tool_Call, status: string) -> string {
	target := ""
	switch call.id {
	case "read_file", "write_file", "get_file_info":
		target = call.filePath
	case "list_directory":
		target = call.directoryPath
	case "run_command":
		target = call.command
	case "search_code", "find_code":
		target = call.query
	case "mcp":
		target = call.mcpServer
	}
	if target == "" {
		return fmt.tprintf("%s (%s)", call.id, status)
	}
	displayTarget := approval_display_text(target, context.temp_allocator)
	return fmt.tprintf("%s: %s (%s)", call.id, displayTarget, status)
}

app_append_tool_history :: proc(
	state: ^App_State,
	call: tool_policy.Tool_Call,
	status: string,
) -> int {
	append_history(state, .Tool, app_tool_history_content(call, status))
	return len(state.history) - 1
}

app_update_tool_history :: proc(
	state: ^App_State,
	historyIndex: int,
	call: tool_policy.Tool_Call,
	status: string,
) {
	if historyIndex < 0 || historyIndex >= len(state.history) {
		return
	}
	entry := &state.history[historyIndex]
	if entry.content != "" {
		delete(entry.content, context.allocator)
	}
	entry.content = strings.clone(app_tool_history_content(call, status), context.allocator)
	entry.cachedLineWidth = 0
	entry.cachedLineCount = 0
	state.historyScrollOffset = 0
	state.historySelection = {}
}

app_history_panel :: proc(state: ^App_State) -> console.Region {
	input_width := state.terminal.columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(
		text_input.input_buffer_string(&state.input),
		input_width,
	)
	layout := compute_app_layout(state.terminal.rows, state.terminal.columns, input_lines)
	return console.panel_interior(console.Panel{region = layout.historyPanel})
}

app_input_panel :: proc(state: ^App_State) -> console.Region {
	input_width := state.terminal.columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(
		text_input.input_buffer_string(&state.input),
		input_width,
	)
	layout := compute_app_layout(state.terminal.rows, state.terminal.columns, input_lines)
	return console.panel_interior(console.Panel{region = layout.inputPanel})
}

input_grapheme_index_at_column :: proc(text: string, column: int) -> int {
	if column <= 0 {
		return 0
	}

	width := 0
	grapheme := 0
	for byteIndex := 0; byteIndex < len(text); {
		if column <= width {
			return grapheme
		}
		width += text_input.unicode_grapheme_width_at(text, byteIndex)
		grapheme += 1
		if column <= width {
			return grapheme
		}
		next := text_input.unicode_next_grapheme_offset(text, byteIndex)
		if next <= byteIndex {
			break
		}
		byteIndex = next
	}
	return grapheme
}

app_input_grapheme_at :: proc(state: ^App_State, row, column: int) -> (int, bool) {
	region := app_input_panel(state)
	if row < region.top_row || row > region.bottom_row {
		return 0, false
	}

	text := text_input.input_buffer_string(&state.input)
	width := console.region_width(region)
	currentRow := region.top_row
	lineStartGrapheme := 0
	lineStart := 0
	for index := 0; index <= len(text) && currentRow <= region.bottom_row; index += 1 {
		if index != len(text) && text[index] != '\n' && text[index] != '\r' {
			continue
		}

		line := text[lineStart:index]
		if len(line) == 0 && currentRow == row {
			return lineStartGrapheme, true
		}
		for start := 0; start < len(line) && currentRow <= region.bottom_row; {
			finish, next := wrapped_text_slice(line, start, width)
			if currentRow == row {
				relativeColumn := column - region.left_column
				return lineStartGrapheme +
					input_grapheme_index_at_column(line[start:finish], relativeColumn),
					true
			}
			currentRow += 1
			lineStartGrapheme += text_input.unicode_grapheme_count(line[start:next])
			if next <= start {
				break
			}
			start = next
		}
		if len(line) == 0 {
			currentRow += 1
		}
		lineStartGrapheme += 1
		lineStart = index + 1
	}
	return 0, false
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
	state.historySelection = {}
	return true
}

app_has_history_selection :: proc(state: ^App_State) -> bool {
	selection := state.historySelection
	return selection.anchorLine != selection.line || selection.anchorColumn != selection.column
}

app_history_selection_bounds :: proc(state: ^App_State) -> (int, int, int, int) {
	selection := state.historySelection
	if selection.anchorLine < selection.line ||
	   (selection.anchorLine == selection.line && selection.anchorColumn <= selection.column) {
		return selection.anchorLine, selection.anchorColumn, selection.line, selection.column
	}
	return selection.line, selection.column, selection.anchorLine, selection.anchorColumn
}

history_visual_line :: proc(
	state: ^App_State,
	width, targetLine: int,
	allocator := context.temp_allocator,
) -> (
	string,
	bool,
) {
	lineNumber := 0
	for index := 0; index < len(state.history); index += 1 {
		text := history_display_line(state, index, allocator)
		start := 0
		for byteIndex := 0; byteIndex <= len(text); byteIndex += 1 {
			if byteIndex != len(text) && text[byteIndex] != '\n' && text[byteIndex] != '\r' {
				continue
			}
			logicalLine := text[start:byteIndex]
			if len(logicalLine) == 0 {
				if lineNumber == targetLine {
					return "", true
				}
				lineNumber += 1
			} else {
				for wrappedStart := 0; wrappedStart < len(logicalLine); {
					finish, next := wrapped_text_slice(logicalLine, wrappedStart, width)
					if lineNumber == targetLine {
						return logicalLine[wrappedStart:finish], true
					}
					lineNumber += 1
					if next <= wrappedStart {
						break
					}
					wrappedStart = next
				}
			}
			start = byteIndex + 1
		}
	}
	return "", false
}

app_history_selection_text :: proc(state: ^App_State, allocator := context.allocator) -> string {
	if !app_has_history_selection(state) {
		return ""
	}

	startLine, startColumn, endLine, endColumn := app_history_selection_bounds(state)
	region := app_history_panel(state)
	width := console.region_width(region)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for lineNumber := startLine; lineNumber <= endLine; lineNumber += 1 {
		line, ok := history_visual_line(state, width, lineNumber, allocator)
		if !ok {
			break
		}
		selectionStart := 0
		selectionEnd := text_input.unicode_text_width(line)
		if lineNumber == startLine {
			selectionStart = startColumn - region.left_column
		}
		if lineNumber == endLine {
			selectionEnd = endColumn - region.left_column
		}
		if selectionStart < 0 {
			selectionStart = 0
		}
		if selectionEnd < selectionStart {
			selectionEnd = selectionStart
		}
		for byteIndex := 0; byteIndex < len(line); {
			graphemeWidth := text_input.unicode_grapheme_width_at(line, byteIndex)
			graphemeEnd := text_input.unicode_text_width(line[:byteIndex]) + graphemeWidth
			graphemeStart := graphemeEnd - graphemeWidth
			if graphemeEnd > selectionStart && graphemeStart < selectionEnd {
				next := text_input.unicode_next_grapheme_offset(line, byteIndex)
				strings.write_string(&builder, line[byteIndex:next])
			}
			next := text_input.unicode_next_grapheme_offset(line, byteIndex)
			if next <= byteIndex {
				break
			}
			byteIndex = next
		}
		if lineNumber < endLine {
			strings.write_byte(&builder, '\n')
		}
	}
	return strings.to_string(builder)
}

app_scroll_history_page :: proc(state: ^App_State, direction: int) -> bool {
	return app_scroll_history(state, direction * console.region_height(app_history_panel(state)))
}

app_handle_mouse_sequence :: proc(state: ^App_State, sequence: string) -> bool {
	event, event_err := console.parse_sgr_mouse_event_response(sequence)
	if event_err != .None {
		return false
	}

	input_width := state.terminal.columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(
		text_input.input_buffer_string(&state.input),
		input_width,
	)
	layout := compute_app_layout(state.terminal.rows, state.terminal.columns, input_lines)
	if event.kind == .Wheel {
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
	}

	input := console.panel_interior(console.Panel{region = layout.inputPanel})
	history := console.panel_interior(console.Panel{region = layout.historyPanel})
	switch event.kind {
	case .Press:
		if event.button != .Left {
			return false
		}
		if event.row >= history.top_row &&
		   event.row <= history.bottom_row &&
		   event.column >= history.left_column &&
		   event.column <= history.right_column {
			firstVisible :=
				history_line_count(state, console.region_width(history)) -
				console.region_height(history) -
				state.historyScrollOffset
			if firstVisible < 0 {
				firstVisible = 0
			}
			line := firstVisible + event.row - history.top_row
			state.historySelection = History_Selection {
				anchorLine   = line,
				anchorColumn = event.column,
				line         = line,
				column       = event.column,
			}
			text_input.input_buffer_clear_selection(&state.input)
			state.mouseSelectionPanel = .History
			return true
		}
		if event.row < input.top_row ||
		   event.row > input.bottom_row ||
		   event.column < input.left_column ||
		   event.column > input.right_column {
			return false
		}
		grapheme, ok := app_input_grapheme_at(state, event.row, event.column)
		if !ok {
			return false
		}
		text_input.input_buffer_select_range(&state.input, grapheme, grapheme)
		state.historySelection = {}
		state.mouseSelectionPanel = .Input
		return true
	case .Motion:
		if state.mouseSelectionPanel == .History &&
		   event.row >= history.top_row &&
		   event.row <= history.bottom_row &&
		   event.column >= history.left_column &&
		   event.column <= history.right_column {
			firstVisible :=
				history_line_count(state, console.region_width(history)) -
				console.region_height(history) -
				state.historyScrollOffset
			if firstVisible < 0 {
				firstVisible = 0
			}
			state.historySelection.line = firstVisible + event.row - history.top_row
			state.historySelection.column = event.column + 1
			return true
		}
		if state.mouseSelectionPanel != .Input ||
		   event.row < input.top_row ||
		   event.row > input.bottom_row ||
		   event.column < input.left_column ||
		   event.column > input.right_column {
			return false
		}
		grapheme, ok := app_input_grapheme_at(state, event.row, event.column + 1)
		if !ok {
			return false
		}
		text_input.input_buffer_extend_selection_to(&state.input, grapheme)
		return true
	case .Release:
		if state.mouseSelectionPanel == .History {
			state.mouseSelectionPanel = .None
			return true
		}
		if state.mouseSelectionPanel != .Input {
			return false
		}
		state.mouseSelectionPanel = .None
		return true
	case .Wheel:
	}
	return false
}

app_handle_input_byte :: proc(state: ^App_State, input: byte) -> bool {
	if state.mode == .Approval {
		return app_handle_approval_input(state, input)
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
		text_input.input_buffer_select_all(&state.input)
		return true
	case 3:
		app_reset_input_utf8_pending(state)
		return app_copy_active_selection(state)
	case 4:
		app_reset_input_utf8_pending(state)
		state.shouldQuit = true
		state.status = "Exiting"
		return true
	case 5:
		app_reset_input_utf8_pending(state)
		text_input.input_buffer_move_cursor_end(&state.input)
		return true
	case 24:
		app_reset_input_utf8_pending(state)
		if text_input.input_buffer_has_selection(&state.input) {
			_, _ = console.osc52_copy_to_clipboard(
				text_input.input_buffer_selection_text(&state.input),
			)
			app_reset_input_history_browse(state)
			text_input.input_buffer_delete_selection(&state.input)
			state.status = "Cut input selection"
			return true
		}
		if app_has_history_selection(state) {
			selected := app_history_selection_text(state, context.allocator)
			_, _ = console.osc52_copy_to_clipboard(selected)
			delete(selected, context.allocator)
			state.status = "Copied history selection"
			return true
		}
	case 8, 127:
		app_reset_input_utf8_pending(state)
		app_reset_input_history_browse(state)
		return text_input.input_buffer_backspace(&state.input)
	case '\r':
		app_reset_input_utf8_pending(state)
		app_submit_input(state)
		return true
	case '\n':
		app_reset_input_utf8_pending(state)
		app_reset_input_history_browse(state)
		text_input.input_buffer_push_byte(&state.input, '\n')
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

app_show_approval :: proc(state: ^App_State, call: tool_policy.Tool_Call) -> bool {
	if !state.dispatcherReady || state.mode == .Approval {
		return false
	}

	approvalCall := tool_policy.tool_call_clone(call, state.dispatcher.allocator)
	prepared := tool_policy.tool_dispatch_prepare(&state.dispatcher, approvalCall)
	if prepared.decision != .Approval_Required || !prepared.actionOK {
		tool_policy.tool_dispatch_result_destroy(&prepared, state.dispatcher.allocator)
		tool_policy.tool_call_destroy(&approvalCall, state.dispatcher.allocator)
		return false
	}

	app_clear_approval(state)
	state.approval.call = approvalCall
	state.approval.callOwned = true
	state.approval.prepared = prepared
	state.approval.preparedOwned = true
	state.approval.historyIndex = -1
	state.approval.choice = .Allow_Once
	state.approval.input = .Ready
	if state.config.approvalMethod == .Approve_Safe ||
	   (state.config.approvalMethod == .Always_Ask && prepared.action.effect == .Execute) {
		app_start_approval_safety(state)
	}
	state.mode = .Approval
	state.status = "Permission approval required"
	return true
}

app_apply_approval_method :: proc(state: ^App_State) -> bool {
	switch state.config.approvalMethod {
	case .Always_Ask:
		return false
	case .Approve_All:
		app_apply_approval_choice(state, .Allow_Once)
		return true
	case .Deny_All:
		app_apply_approval_choice(state, .Deny)
		return true
	case .Approve_Safe:
		if !app_safety_allows_automatic_approval(
			app_approval_safety_ready(state),
			app_approval_safety_unavailable(state),
			app_approval_safety_verdict(state),
		) {
			return false
		}
		app_apply_approval_choice(state, .Allow_Once)
		return true
	}
	return false
}

app_safety_allows_automatic_approval :: proc(
	ready, unavailable: bool,
	verdict: approval_safety.Verdict,
) -> bool {
	return ready && !unavailable && verdict == .Safe
}

app_clear_approval :: proc(state: ^App_State) {
	app_destroy_approval_safety(&state.approval.safety)
	if state.approval.callOwned {
		tool_policy.tool_call_destroy(&state.approval.call, state.dispatcher.allocator)
	}
	if state.approval.preparedOwned {
		tool_policy.tool_dispatch_result_destroy(
			&state.approval.prepared,
			state.dispatcher.allocator,
		)
	}
	delete(state.approval.agentRequestID, state.dispatcher.allocator)
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
	return app_handle_approval_input_with_safety_ready(
		state,
		input,
		app_approval_safety_ready(state),
	)
}

app_handle_approval_input_with_safety_ready :: proc(
	state: ^App_State,
	input: byte,
	safetyReady: bool,
) -> bool {
	if !safetyReady {
		return false
	}

	switch state.approval.input {
	case .Escape:
		if input == '[' {
			state.approval.input = .CSI
			return false
		}
		app_apply_approval_choice(state, .Deny)
		return true
	case .CSI:
		if input == '<' {
			state.approval.input = .CSI_Mouse
			return false
		}
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
	case .CSI_Mouse:
		if input == 'M' || input == 'm' {
			state.approval.input = .Ready
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
		if state.approval.historyIndex >= 0 {
			app_update_tool_history(
				state,
				state.approval.historyIndex,
				state.approval.call,
				"denied",
			)
		}
		if !agent.agent_id_is_none(state.approval.agentID) && state.approval.agentRequestID != "" {
			_ = agent.runtime_resolve_tool(
				&state.agentHost.runtime,
				state.approval.agentID,
				state.approval.agentRequestID,
				.Denied,
				output,
			)
		}
		state.status = "Tool call denied"
		state.mode = .Chat
		app_clear_approval(state)
		return
	}

	if choice == .Allow_Session || choice == .Allow_Always {
		grant, grantOK := tool_policy.tool_dispatch_grant_from_action(
			state.approval.prepared.action,
			state.dispatcher.allocator,
		)
		if !grantOK {
			state.status = "Tool call requires one-time approval"
			return
		}

		if choice == .Allow_Session {
			grantOK = tool_policy.tool_dispatcher_add_session_grant(&state.dispatcher, grant)
			tool_policy.permission_grant_destroy(&grant, state.dispatcher.allocator)
		} else {
			append(&state.config.permissionGrants, grant)
			state.dispatcher.persistentGrants = state.config.permissionGrants[:]
			if state.configHome != "" &&
			   settings.save_config_to_file(state.configHome, state.config) != .None {
				grant = pop(&state.config.permissionGrants)
				tool_policy.permission_grant_destroy(&grant, state.dispatcher.allocator)
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

	if agent.agent_id_is_none(state.approval.agentID) || state.approval.agentRequestID == "" {
		state.status = "Tool call is no longer active"
		state.mode = .Chat
		app_clear_approval(state)
		return
	}

	if state.approval.historyIndex < 0 {
		state.approval.historyIndex = app_append_tool_history(
			state,
			state.approval.call,
			"running",
		)
	} else {
		app_update_tool_history(state, state.approval.historyIndex, state.approval.call, "running")
	}
	started := app_start_agent_tool_execution(
		state,
		state.approval.call,
		state.approval.historyIndex,
		state.approval.agentID,
		state.approval.agentRequestID,
	)
	state.mode = .Chat
	app_clear_approval(state)
	if !started {
		state.status = "Tool call could not start"
	}
}

app_handle_text_input_byte :: proc(state: ^App_State, input: byte) -> bool {
	if input < utf8.RUNE_SELF {
		app_reset_input_utf8_pending(state)
		text_input.input_buffer_push_byte(&state.input, input)
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

	text_input.input_buffer_push_text(
		&state.input,
		string(state.inputUTF8Pending[:expectedLength]),
	)
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
	state.inputEscapeModifier = 0
	state.inputMouseSequenceLen = 0
}

app_reset_input_paste :: proc(state: ^App_State) {
	clear(&state.inputPaste)
	app_reset_input_escape(state)
}

app_handle_cursor_escape :: proc(state: ^App_State, input: byte, extend: bool) -> bool {
	if extend {
		cursor := text_input.input_buffer_cursor_position(&state.input)
		switch input {
		case 'C':
			text_input.input_buffer_extend_selection_to(&state.input, cursor + 1)
		case 'D':
			text_input.input_buffer_extend_selection_to(&state.input, cursor - 1)
		case 'H':
			text_input.input_buffer_extend_selection_to(&state.input, 0)
		case 'F':
			text_input.input_buffer_extend_selection_to(
				&state.input,
				text_input.unicode_grapheme_count(text_input.input_buffer_string(&state.input)),
			)
		case:
			return false
		}
		return true
	}

	switch input {
	case 'C':
		return text_input.input_buffer_move_cursor_right(&state.input)
	case 'D':
		return text_input.input_buffer_move_cursor_left(&state.input)
	case 'H':
		text_input.input_buffer_move_cursor_start(&state.input)
		return true
	case 'F':
		text_input.input_buffer_move_cursor_end(&state.input)
		return true
	}
	return false
}

app_copy_active_selection :: proc(state: ^App_State) -> bool {
	if text_input.input_buffer_has_selection(&state.input) {
		_, _ = console.osc52_copy_to_clipboard(
			text_input.input_buffer_selection_text(&state.input),
		)
		state.status = "Copied input selection"
		return true
	}
	if app_has_history_selection(state) {
		selected := app_history_selection_text(state, context.allocator)
		_, _ = console.osc52_copy_to_clipboard(selected)
		delete(selected, context.allocator)
		state.status = "Copied history selection"
		return true
	}
	state.status = "No selection to copy"
	return true
}

app_input_paste_ends :: proc(state: ^App_State) -> bool {
	terminator := "\x1b[201~"
	if len(state.inputPaste) < len(terminator) {
		return false
	}
	start := len(state.inputPaste) - len(terminator)
	return string(state.inputPaste[start:]) == terminator
}

app_finish_input_paste :: proc(state: ^App_State) {
	terminator_length := len("\x1b[201~")
	text := string(state.inputPaste[:len(state.inputPaste) - terminator_length])
	app_reset_input_history_browse(state)
	text_input.input_buffer_push_text(&state.input, text)
	app_reset_input_paste(state)
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
		case 'C', 'D', 'H', 'F':
			app_reset_input_escape(state)
			return app_handle_cursor_escape(state, input, false)
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
			case 200:
				clear(&state.inputPaste)
				state.inputEscape = .Paste
				return false
			case 5:
				return app_scroll_history_page(state, 1)
			case 6:
				return app_scroll_history_page(state, -1)
			case 1, 7:
				text_input.input_buffer_move_cursor_start(&state.input)
				return true
			case 3:
				return text_input.input_buffer_delete_at_cursor(&state.input)
			case 4, 8:
				text_input.input_buffer_move_cursor_end(&state.input)
				return true
			case:
				return true
			}
		case ';':
			state.inputEscapeModifier = 0
			state.inputEscape = .CSI_Modifier
			return false
		case:
			app_reset_input_escape(state)
			return true
		}
	case .CSI_Modifier:
		switch input {
		case '0' ..= '9':
			state.inputEscapeModifier = state.inputEscapeModifier * 10 + int(input - '0')
			return false
		case '~':
			parameter := state.inputEscapeParameter
			modifier := state.inputEscapeModifier
			app_reset_input_escape(state)
			if parameter == 2 && modifier == 5 {
				return app_copy_active_selection(state)
			}
			if parameter == 2 && modifier == 2 {
				return true
			}
			return true
		case 'C', 'D', 'H', 'F':
			extend := state.inputEscapeModifier == 2
			app_reset_input_escape(state)
			return app_handle_cursor_escape(state, input, extend)
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
	case .Paste:
		append(&state.inputPaste, input)
		if !app_input_paste_ends(state) {
			return false
		}
		app_finish_input_paste(state)
		return true
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
	append(&state.inputHistory, strings.clone(text, state.allocator))
	app_reset_input_history_browse(state)
	if state.configHome != "" && state.workingDirectory != "" {
		if input_history.save(state.configHome, state.workingDirectory, state.inputHistory[:]) !=
		   .None {
			state.status = "Input history could not be saved"
		}
	}
}

app_load_input_history :: proc(state: ^App_State, allocator := context.allocator) {
	if state.configHome == "" || state.workingDirectory == "" {
		return
	}

	loaded, loadErr := input_history.load(state.configHome, state.workingDirectory, allocator)
	if loadErr != .None {
		return
	}
	delete(state.inputHistory)
	state.inputHistory = loaded
}

app_clear_input_history :: proc(state: ^App_State) {
	if app_agent_host_stream_active(state) {
		app_cancel_agent_host_stream(state)
	}
	state.agentHost.historyIndex = -1
	state.agentHost.thinking = false
	state.agentHost.spinnerVisible = false
	for &entry in state.inputHistory {
		delete(entry, state.allocator)
		entry = ""
	}
	clear(&state.inputHistory)
	app_reset_input_history_browse(state)
	for &entry in state.history {
		delete(entry.content, context.allocator)
		entry = {}
	}
	clear(&state.history)
	state.historyScrollOffset = 0
	state.historySelection = {}

	if state.configHome == "" || state.workingDirectory == "" {
		state.status = "Input history cleared"
		return
	}
	if input_history.clear(state.configHome, state.workingDirectory) == .None {
		state.status = "Input history cleared"
	} else {
		state.status = "Input history could not be cleared"
	}
}

app_reset_input_history_browse :: proc(state: ^App_State) {
	state.inputHistoryCursor = -1
	if state.inputHistoryDraft != "" {
		delete(state.inputHistoryDraft, state.allocator)
		state.inputHistoryDraft = ""
	}
}

app_input_history_previous :: proc(state: ^App_State) -> bool {
	if len(state.inputHistory) == 0 {
		return false
	}

	if state.inputHistoryCursor < 0 {
		current := text_input.input_buffer_string(&state.input)
		if current != "" {
			state.inputHistoryDraft = strings.clone(current, state.allocator)
		}
		state.inputHistoryCursor = len(state.inputHistory) - 1
	} else if state.inputHistoryCursor > 0 {
		state.inputHistoryCursor -= 1
	}

	text_input.input_buffer_set_text(&state.input, state.inputHistory[state.inputHistoryCursor])
	text_input.input_buffer_move_cursor_end(&state.input)
	return true
}

app_input_history_next :: proc(state: ^App_State) -> bool {
	if state.inputHistoryCursor < 0 {
		return false
	}

	if state.inputHistoryCursor < len(state.inputHistory) - 1 {
		state.inputHistoryCursor += 1
		text_input.input_buffer_set_text(
			&state.input,
			state.inputHistory[state.inputHistoryCursor],
		)
		text_input.input_buffer_move_cursor_end(&state.input)
		return true
	}

	text_input.input_buffer_set_text(&state.input, state.inputHistoryDraft)
	app_reset_input_history_browse(state)
	return true
}

app_submit_input :: proc(state: ^App_State) {
	text := text_input.input_buffer_submit(&state.input, context.allocator)
	defer delete(text, context.allocator)
	if state.mode == .Setup {
		app_submit_setup_input(state, text)
		return
	}

	if text == "" {
		state.status = "Ready"
		return
	}

	command := commands.parse_slash_command(text)
	if command.isCommand {
		app_run_command(state, command)
		return
	}

	app_record_input_history(state, text)

	if app_agent_host_stream_active(state) {
		state.status = "Assistant stream already active; use /stop first"
		return
	}

	append_history(state, .User, text)
	_ = app_start_agent_host_stream(state)
}

app_run_command :: proc(state: ^App_State, command: commands.Parsed_Command) {
	switch command.kind {
	case commands.Slash_Command.Exit:
		state.shouldQuit = true
		state.status = "Exiting"
	case commands.Slash_Command.Config:
		app_show_config(state)
	case commands.Slash_Command.Help:
		append_history(state, .Assistant, "Commands: /exit, /config, /help, /stop, /clear")
		state.status = "Help displayed"
	case commands.Slash_Command.Stop:
		app_cancel_agent_host_stream(state)
	case commands.Slash_Command.Clear:
		app_clear_input_history(state)
	case commands.Slash_Command.Unknown:
		state.status = "Unknown command"
	case commands.Slash_Command.None:
		state.status = "Ready"
	}
}

app_submit_setup_input :: proc(state: ^App_State, text: string) {
	switch state.setupStep {
	case .Endpoint:
		endpoint := text
		if endpoint == "" {
			endpoint = settings.DEFAULT_CONFIG_ENDPOINT
		}
		if state.setupEndpoint != "" {
			delete(state.setupEndpoint, context.allocator)
		}
		state.setupEndpoint = strings.clone(endpoint, context.allocator)
		state.setupStep = .API_Key
		state.status = "Setup: enter optional API key, or press Enter"
	case .API_Key:
		if state.setupAPIKey != "" {
			delete(state.setupAPIKey, context.allocator)
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
	defer ai.models_destroy(&models, context.allocator)

	delete(state.config.providers)
	delete(state.config.mcpServers)
	delete(state.config.skillPaths)
	delete(state.config.permissionGrants)
	state.config = settings.default_ollama_config(context.allocator)
	state.config.providers[0].endpoint = strings.clone(state.setupEndpoint, context.allocator)
	state.config.providers[0].endpointOwned = true
	state.config.providers[0].apiKey = strings.clone(state.setupAPIKey, context.allocator)
	state.config.providers[0].apiKeyOwned = true
	for model in models {
		if !ai.model_supports_chat(model) {
			continue
		}
		state.config.selectedModel = strings.clone(model.name, context.allocator)
		state.modelNameOwned = true
		state.config.providers[0].model = strings.clone(model.name, context.allocator)
		state.config.providers[0].modelOwned = true
		break
	}

	ai.clear_interfaces()
	ai.add_interface_with_models(
		state.config.providers[0].name,
		state.config.providers[0].type,
		state.config.providers[0].endpoint,
		models[:],
	)

	delete(state.mcp.servers)
	state.mcp = settings.mcp_registry_from_config(state.config.mcpServers[:], context.allocator)
	state.mode = .Chat
	if settings.save_config_to_file(state.configHome, state.config) == .None {
		state.status = "Setup complete; config saved"
	} else {
		state.status = "Setup complete; config save failed"
	}
}

app_show_config :: proc(state: ^App_State) {
	if app_agent_host_stream_active(state) {
		state.status = "Assistant stream active; use /stop before changing config"
		return
	}

	state.configCategory = .Providers
	state.configFocus = .Categories
	state.configInput = .Ready
	state.configSettingCursor = 0
	state.configProviderIndex = app_config_active_provider_index(state)
	state.configEditing = false
	widgets.text_editor_clear(&state.configEditor)
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
					id = .Provider_Context_Window,
					kind = .Text,
					providerIndex = providerIndex,
				},
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
	case .Chat_Model:
		app_rebuild_model_entries(state, context.allocator)
		for _, index in state.models {
			if !app_model_entry_supports_chat(state.models[index]) {
				continue
			}
			append(
				&state.configSettings,
				Config_Setting{id = .Chat_Model, kind = .Single_Select, modelIndex = index},
			)
		}
	case .Embedding_Model:
		app_rebuild_model_entries(state, context.allocator)
		for _, index in state.models {
			if app_model_entry_supports_embeddings(state.models[index]) {
				append(
					&state.configSettings,
					Config_Setting {
						id = .Embedding_Model,
						kind = .Single_Select,
						modelIndex = index,
					},
				)
			}
		}
	case .Safety_Model:
		app_rebuild_model_entries(state, context.allocator)
		for _, index in state.models {
			if !app_model_entry_supports_chat(state.models[index]) {
				continue
			}
			append(
				&state.configSettings,
				Config_Setting{id = .Safety_Model, kind = .Single_Select, modelIndex = index},
			)
		}
	case .Advanced:
		append(&state.configSettings, Config_Setting{id = .Approval_Method, kind = .Single_Select})
		append(&state.configSettings, Config_Setting{id = .Tool_Continuations, kind = .Text})
		append(
			&state.configSettings,
			Config_Setting{id = .System_Prompt_Mode, kind = .Single_Select},
		)
		append(&state.configSettings, Config_Setting{id = .System_Prompt, kind = .Text})
		append(&state.configSettings, Config_Setting{id = .Reset_System_Prompt, kind = .Button})
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
			category = int(Config_Category.Advanced)
		} else if category > int(Config_Category.Advanced) {
			category = int(Config_Category.Providers)
		}
		state.configCategory = Config_Category(category)
		state.configSettingCursor = 0
		app_rebuild_config_settings(state)
	} else if len(state.configSettings) > 0 {
		state.configSettingCursor = widgets.list_cursor_after_move(
			state.configSettingCursor,
			len(state.configSettings),
			delta,
		)
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
	case .Provider_Name,
	     .Provider_Endpoint,
	     .Provider_API_Key,
	     .Provider_Model,
	     .Provider_Context_Window,
	     .Tool_Continuations,
	     .System_Prompt:
		app_begin_config_edit(state, setting)
	case .Refresh_Models:
		app_refresh_config_models(state, setting.providerIndex)
	case .Add_Provider:
		app_add_config_provider(state)
	case .Remove_Provider:
		app_remove_config_provider(state, setting.providerIndex)
	case .Chat_Model:
		app_select_config_model(state, setting.modelIndex)
	case .Embedding_Model:
		app_select_config_embedding_model(state, setting.modelIndex)
	case .Safety_Model:
		app_select_config_safety_model(state, setting.modelIndex)
	case .Approval_Method:
		app_cycle_approval_method(state)
	case .System_Prompt_Mode:
		app_cycle_system_prompt_mode(state)
	case .Reset_System_Prompt:
		app_reset_system_prompt(state)
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
		provider.type = .None
	case .None:
		provider.type = .Ollama
	}
	app_apply_config_change(state, "Provider type saved")
}

app_cycle_approval_method :: proc(state: ^App_State) {
	switch state.config.approvalMethod {
	case .Always_Ask:
		state.config.approvalMethod = .Approve_Safe
	case .Approve_Safe:
		state.config.approvalMethod = .Approve_All
	case .Approve_All:
		state.config.approvalMethod = .Deny_All
	case .Deny_All:
		state.config.approvalMethod = .Always_Ask
	}
	app_apply_config_change(state, "Approval method saved")
}

app_cycle_system_prompt_mode :: proc(state: ^App_State) {
	switch state.config.systemPromptMode {
	case .Append:
		state.config.systemPromptMode = .Replace
	case .Replace:
		state.config.systemPromptMode = .Append
	}
	app_apply_config_change(state, "System prompt mode saved")
}

app_reset_system_prompt :: proc(state: ^App_State) {
	if state.config.systemPrompt != "" {
		delete(state.config.systemPrompt, state.config.allocationAllocator)
	}
	state.config.systemPrompt = ""
	state.config.systemPromptMode = .Append
	app_apply_config_change(state, "System prompt reset")
}

app_begin_config_edit :: proc(state: ^App_State, setting: Config_Setting) {
	if setting.id == .System_Prompt {
		widgets.text_editor_set_text(&state.configEditor, state.config.systemPrompt)
		state.configEditingSetting = setting
		state.configEditing = true
		state.status = "Editing system prompt: Ctrl-S saves, Esc cancels"
		return
	}
	if setting.id == .Tool_Continuations {
		widgets.text_editor_set_text(
			&state.configEditor,
			fmt.tprintf("%d", state.config.toolContinuations),
		)
		state.configEditingSetting = setting
		state.configEditing = true
		state.status = "Editing: Enter saves, Esc cancels"
		return
	}
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
	case .Provider_Context_Window:
		value = fmt.tprintf(
			"%d",
			settings.config_context_window_tokens(&state.config, provider.name, provider.model),
		)
	case:
		return
	}
	widgets.text_editor_set_text(&state.configEditor, value)
	state.configEditingSetting = setting
	state.configEditing = true
	state.status = "Editing: Enter saves, Esc cancels"
}

app_handle_config_edit_input :: proc(state: ^App_State, input: byte) -> bool {
	if state.configEditingSetting.id == .System_Prompt {
		handled, event := widgets.text_editor_handle_multiline_byte(&state.configEditor, input)
		return app_handle_config_edit_event(state, handled, event)
	}
	handled, event := widgets.text_editor_handle_byte(&state.configEditor, input)
	return app_handle_config_edit_event(state, handled, event)
}

app_handle_config_edit_event :: proc(
	state: ^App_State,
	handled: bool,
	event: widgets.Text_Editor_Event,
) -> bool {
	switch event {
	case .None:
	case .Commit:
		app_commit_config_edit(state)
	case .Cancel:
		state.configEditing = false
		widgets.text_editor_clear(&state.configEditor)
		state.status = "Config edit canceled"
	}
	return handled
}

app_commit_config_edit :: proc(state: ^App_State) {
	setting := state.configEditingSetting
	text := widgets.text_editor_string(&state.configEditor)
	state.configEditing = false
	widgets.text_editor_clear(&state.configEditor)

	if setting.id == .Tool_Continuations {
		continuations, continuationsOK := strconv.parse_int(text)
		if !continuationsOK || continuations < 1 {
			state.status = "Tool continuation limit must be a positive integer"
			return
		}
		state.config.toolContinuations = continuations
		app_apply_config_change(state, "Tool continuation limit saved")
		return
	}
	if setting.id == .System_Prompt {
		if state.config.systemPrompt != "" {
			delete(state.config.systemPrompt, state.config.allocationAllocator)
		}
		state.config.systemPrompt = ""
		if text != "" {
			state.config.systemPrompt = strings.clone(text, state.config.allocationAllocator)
		}
		app_apply_config_change(state, "System prompt saved")
		return
	}
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
			if (state.configStringsOwned || state.modelProviderOwned) &&
			   state.config.selectedProvider != "" {
				delete(state.config.selectedProvider, context.allocator)
			}
			state.config.selectedProvider = strings.clone(text, context.allocator)
			state.modelProviderOwned = true
		}
		if state.config.safetyProvider == oldName {
			if (state.configStringsOwned || state.safetyProviderOwned) &&
			   state.config.safetyProvider != "" {
				delete(state.config.safetyProvider, context.allocator)
			}
			state.config.safetyProvider = strings.clone(text, context.allocator)
			state.safetyProviderOwned = true
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
			if (state.configStringsOwned || state.modelNameOwned) &&
			   state.config.selectedModel != "" {
				delete(state.config.selectedModel, context.allocator)
			}
			state.config.selectedModel = strings.clone(text, context.allocator)
			state.modelNameOwned = true
		}
	} else if setting.id == .Provider_Context_Window {
		tokens, tokensOK := strconv.parse_int(text)
		if !tokensOK || tokens < 0 {
			state.status = "Context window must be a nonnegative integer"
			return
		}
		provider := state.config.providers[setting.providerIndex]
		if provider.model == "" ||
		   !settings.config_set_context_window_tokens(
				   &state.config,
				   provider.name,
				   provider.model,
				   tokens,
			   ) {
			state.status = "Set a configured model before context window"
			return
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
		settings.Provider_Config {
			name = strings.clone(name, context.allocator),
			type = .Ollama,
			endpoint = strings.clone(settings.DEFAULT_CONFIG_ENDPOINT, context.allocator),
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
	if state.config.providers[providerIndex].name == state.config.safetyProvider {
		state.status = "Choose another safety model before removing this provider"
		return
	}
	settings.provider_config_destroy(&state.config.providers[providerIndex], context.allocator)
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
	defer ai.models_destroy(&models, context.allocator)
	contextClient, contextClientErr := ai.new_client_with_endpoint(
		.Ollama,
		provider.endpoint,
		provider.apiKey,
	)
	contextWindowsChanged := false
	if contextClientErr == .None {
		for model in models {
			contextWindowTokens, contextWindowErr := ai.get_ollama_model_context_window(
				contextClient,
				model.name,
			)
			if contextWindowErr == .None && contextWindowTokens > 0 {
				contextWindowsChanged =
					settings.config_update_context_window_tokens(
						&state.config,
						provider.name,
						model.name,
						contextWindowTokens,
					) ||
					contextWindowsChanged
			}
		}
	}
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
	if contextWindowsChanged &&
	   state.configHome != "" &&
	   settings.save_config_to_file(state.configHome, state.config) != .None {
		state.status = "Provider models refreshed; context window save failed"
		return
	}
	if contextWindowsChanged {
		state.status = "Provider models and context windows refreshed"
		return
	}
	state.status = "Provider models refreshed"
}

app_select_config_model :: proc(state: ^App_State, modelIndex: int) {
	if modelIndex < 0 || modelIndex >= len(state.models) {
		return
	}
	entry := state.models[modelIndex]
	if !app_model_entry_supports_chat(entry) {
		state.status = "Selected model does not support chat tools"
		return
	}
	if (state.configStringsOwned || state.modelProviderOwned) &&
	   state.config.selectedProvider != "" {
		delete(state.config.selectedProvider, context.allocator)
	}
	if (state.configStringsOwned || state.modelNameOwned) && state.config.selectedModel != "" {
		delete(state.config.selectedModel, context.allocator)
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

app_model_entry_supports_chat :: proc(entry: Model_Select_Entry) -> bool {
	return entry.supportsChat
}

app_model_entry_supports_embeddings :: proc(entry: Model_Select_Entry) -> bool {
	return entry.supportsEmbeddings
}

app_select_config_embedding_model :: proc(state: ^App_State, modelIndex: int) {
	if modelIndex < 0 || modelIndex >= len(state.models) {
		return
	}

	entry := state.models[modelIndex]
	if !app_model_entry_supports_embeddings(entry) {
		state.status = "Selected model does not support embeddings"
		return
	}
	if state.embeddingProviderOwned && state.config.embeddingProvider != "" {
		delete(state.config.embeddingProvider, context.allocator)
	}
	if state.embeddingModelOwned && state.config.embeddingModel != "" {
		delete(state.config.embeddingModel, context.allocator)
	}
	state.config.embeddingProvider = strings.clone(entry.providerName, context.allocator)
	state.config.embeddingModel = strings.clone(entry.model, context.allocator)
	state.embeddingProviderOwned = true
	state.embeddingModelOwned = true
	app_apply_config_change(state, "Embedding model selected and saved")
}

app_select_config_safety_model :: proc(state: ^App_State, modelIndex: int) {
	if modelIndex < 0 || modelIndex >= len(state.models) {
		return
	}

	entry := state.models[modelIndex]
	if !app_model_entry_supports_chat(entry) {
		state.status = "Selected model does not support chat tools"
		return
	}
	if (state.configStringsOwned || state.safetyProviderOwned) &&
	   state.config.safetyProvider != "" {
		delete(state.config.safetyProvider, context.allocator)
	}
	if (state.configStringsOwned || state.safetyModelOwned) && state.config.safetyModel != "" {
		delete(state.config.safetyModel, context.allocator)
	}
	state.config.safetyProvider = strings.clone(entry.providerName, context.allocator)
	state.config.safetyModel = strings.clone(entry.model, context.allocator)
	state.safetyProviderOwned = true
	state.safetyModelOwned = true
	app_apply_config_change(state, "Safety model selected and saved")
}

app_apply_config_change :: proc(state: ^App_State, successStatus: string) {
	ai.clear_interfaces()
	app_register_config_interfaces(state.config, false, context.allocator)
	app_rebuild_model_entries(state, context.allocator)
	if state.configHome != "" &&
	   settings.save_config_to_file(state.configHome, state.config) != .None {
		state.status = "Config changed; save failed"
		return
	}
	app_rebuild_code_index(state, context.allocator)
	state.status = successStatus
}

app_rebuild_code_index :: proc(state: ^App_State, allocator := context.allocator) {
	if state.codeIndexReady {
		code_index.code_index_destroy(&state.codeIndex, allocator)
		state.codeIndexReady = false
	}
	if state.configHome == "" ||
	   state.workingDirectory == "" ||
	   state.config.embeddingProvider == "" ||
	   state.config.embeddingModel == "" {
		return
	}

	cacheDir := input_history.cache_directory(state.configHome, allocator)
	defer delete(cacheDir, allocator)
	index, initError := code_index.code_index_init(
		state.workingDirectory,
		cacheDir,
		state.config.embeddingProvider,
		state.config.embeddingModel,
		allocator,
	)
	if initError != .None {
		return
	}
	state.codeIndex = index
	state.codeIndexReady = true
	_ = code_index.code_index_load(&state.codeIndex, allocator)
}

app_embedding_client :: proc(state: ^App_State) -> (ai.Client, ai.AI_Error) {
	if state == nil || state.config.embeddingProvider == "" || state.config.embeddingModel == "" {
		return ai.Client{}, .Invalid_Request
	}
	provider, providerOK := app_find_provider(state.config, state.config.embeddingProvider)
	if !providerOK || !provider.enabled {
		return ai.Client{}, .Interface_Not_Found
	}
	if provider.type != .Ollama {
		return ai.Client{}, .Unsupported_Interface
	}
	return ai.new_client(provider.name, provider.apiKey)
}

app_ensure_code_index :: proc(state: ^App_State, allocator := context.allocator) -> ai.AI_Error {
	if state == nil {
		return .Invalid_Request
	}
	if !state.codeIndexReady {
		app_rebuild_code_index(state, allocator)
	}
	if !state.codeIndexReady {
		return .Invalid_Request
	}
	if state.codeIndex.databaseInitialized {
		return .None
	}
	client, clientError := app_embedding_client(state)
	if clientError != .None {
		return clientError
	}
	rebuildError := code_index.code_index_rebuild(
		&state.codeIndex,
		client,
		code_index.CODE_INDEX_DEFAULT_CHUNK_LINES,
		code_index.CODE_INDEX_DEFAULT_CHUNK_OVERLAP_LINES,
		allocator,
	)
	if rebuildError != .None {
		return rebuildError
	}
	if code_index.code_index_save(&state.codeIndex) != .None {
		return .Provider_Error
	}
	return .None
}

app_search_code :: proc(
	state: ^App_State,
	query: string,
	maximumResults: int,
	allocator := context.allocator,
) -> (
	[dynamic]code_index.Code_Search_Result,
	ai.AI_Error,
) {
	results := make([dynamic]code_index.Code_Search_Result, 0, 0, allocator)
	ensureError := app_ensure_code_index(state, allocator)
	if ensureError != .None {
		return results, ensureError
	}
	client, clientError := app_embedding_client(state)
	if clientError != .None {
		return results, clientError
	}
	delete(results)
	return code_index.code_index_search_text(
		&state.codeIndex,
		client,
		query,
		maximumResults,
		allocator,
	)
}

app_find_code :: proc(
	state: ^App_State,
	query: string,
	maximumResults: int,
	allocator := context.allocator,
) -> [dynamic]code_index.Code_Search_Result {
	results := make([dynamic]code_index.Code_Search_Result, 0, 0, allocator)
	if state == nil || state.dispatcher.projectRoot == "" {
		return results
	}
	delete(results)
	index := code_index.Code_Index {
		projectRoot = state.dispatcher.projectRoot,
	}
	return code_index.code_index_find_text(&index, query, maximumResults, allocator)
}

app_clear_model_entries :: proc(state: ^App_State) {
	for entry in state.models {
		delete(entry.providerName, context.allocator)
		delete(entry.model, context.allocator)
	}
	clear(&state.models)
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
				ai.models_destroy(&models, allocator)
			}
		}

		if !added && provider.model != "" {
			app_append_model_entry(state, provider, ai.Model{name = provider.model}, allocator)
		}
	}
}

app_append_model_entry :: proc(
	state: ^App_State,
	provider: settings.Provider_Config,
	model: ai.Model,
	allocator := context.allocator,
) {
	append(
		&state.models,
		Model_Select_Entry {
			providerName = strings.clone(provider.name, allocator),
			providerType = provider.type,
			model = strings.clone(model.name, allocator),
			supportsChat = provider.type != .Ollama || ai.model_supports_chat(model),
			supportsEmbeddings = provider.type == .Ollama || ai.model_supports_embeddings(model),
		},
	)
}

app_find_provider :: proc(
	config: settings.Mimir_Config,
	name: string,
) -> (
	settings.Provider_Config,
	bool,
) {
	for provider in config.providers {
		if provider.name == name {
			return provider, true
		}
	}
	return settings.Provider_Config{}, false
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

	for model in iface.models {
		if iface.type == .Ollama && !ai.model_supports_chat(model) {
			continue
		}
		state.config.selectedModel = strings.clone(model.name, allocator)
		state.modelNameOwned = true
		for &provider in state.config.providers {
			if provider.name == state.config.selectedProvider && provider.model == "" {
				provider.model = strings.clone(model.name, allocator)
				provider.modelOwned = true
				return
			}
		}
		return
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
