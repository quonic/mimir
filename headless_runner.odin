package main

import "ai"
import "commands"
import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "settings"
import "text_input"
import "widgets"

headless_json_flag_present :: proc(args: []string) -> bool {
	for arg in args[1:] {
		if arg == "--headless-json" {
			return true
		}
	}
	return false
}

run_headless_jsonl :: proc() {
	state := app_init(context.allocator)
	defer app_destroy(&state)
	pending := make([dynamic]byte, 0, 4096, context.allocator)
	defer delete(pending)

	for !state.shouldQuit {
		line, ok := headless_read_line(&pending, context.allocator)
		if !ok {
			break
		}
		if line == "" {
			delete(line, context.allocator)
			continue
		}

		request, message, parsed := headless_parse_request(line, context.allocator)
		if !parsed {
			headless_write_error(nil, "parse_error", message)
			delete(line, context.allocator)
			continue
		}
		headless_dispatch_request(&state, &request)
		headless_request_destroy(&request, context.allocator)
		delete(line, context.allocator)
	}
}

headless_read_line :: proc(
	pending: ^[dynamic]byte,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	for {
		for index := 0; index < len(pending); index += 1 {
			if pending[index] == '\n' {
				line := strings.clone(string(pending[:index]), allocator)
				remainderLength := len(pending) - index - 1
				remainder := make([dynamic]byte, remainderLength, cap(pending), allocator)
				copy(remainder[:], pending[index + 1:])
				delete(pending^)
				pending^ = remainder
				return line, true
			}
		}

		buffer: [4096]byte
		read, readErr := os.read(os.stdin, buffer[:])
		if readErr != nil || read == 0 {
			if len(pending) > 0 {
				line := strings.clone(string(pending[:]), allocator)
				clear(pending)
				return line, true
			}
			return "", false
		}
		append(pending, ..buffer[:read])
	}
}

headless_dispatch_request :: proc(state: ^App_State, request: ^Headless_Request) {
	switch request.action {
	case "shutdown":
		state.shouldQuit = true
		state.status = "Exiting"
		headless_write_ack(request, state)
	case "run_command":
		headless_handle_run_command(state, request)
	case "send_message":
		headless_handle_send_message(state, request)
	case "get_history":
		headless_write_history(request, state)
	case "get_config":
		headless_handle_get_config(state, request)
	case "set_config":
		headless_handle_set_config(state, request)
	case "approve":
		headless_handle_approve(state, request)
	case "deny":
		app_apply_approval_choice(state, .Deny)
		headless_poll_once(state)
		headless_write_ack(request, state)
	case "key", "input_event":
		headless_handle_key(state, request)
	case "wait_until_idle":
		headless_wait_until_idle(state)
		headless_write_status("idle", request, state)
	case:
		headless_write_error(request, "unknown_action", "unknown action")
	}
}

headless_handle_run_command :: proc(state: ^App_State, request: ^Headless_Request) {
	commandValue, hasCommand := request.object["command"]
	if !hasCommand {
		headless_write_error(request, "invalid_request", "missing command")
		return
	}
	commandText, commandOK := commandValue.(json.String)
	if !commandOK || string(commandText) == "" {
		headless_write_error(request, "invalid_request", "command must be a non-empty string")
		return
	}
	command := commands.parse_slash_command(string(commandText))
	if !command.isCommand {
		headless_write_error(request, "invalid_request", "command must be a slash command")
		return
	}
	app_run_command(state, command)
	headless_poll_once(state)
	headless_write_ack(request, state)
}

headless_handle_approve :: proc(state: ^App_State, request: ^Headless_Request) {
	choice := Approval_Choice.Allow_Once
	if scopeValue, hasScope := request.object["scope"]; hasScope {
		scope, scopeOK := scopeValue.(json.String)
		if !scopeOK {
			headless_write_error(request, "invalid_request", "scope must be a string")
			return
		}
		switch string(scope) {
		case "once", "":
			choice = .Allow_Once
		case "session":
			choice = .Allow_Session
		case "always":
			choice = .Allow_Always
		case:
			headless_write_error(
				request,
				"invalid_request",
				"scope must be once, session, or always",
			)
			return
		}
	}
	app_apply_approval_choice(state, choice)
	headless_poll_once(state)
	headless_write_ack(request, state)
}

headless_handle_get_config :: proc(state: ^App_State, request: ^Headless_Request) {
	if pathValue, hasPath := request.object["path"]; hasPath {
		path, pathOK := pathValue.(json.String)
		if !pathOK || string(path) == "" {
			headless_write_error(request, "invalid_request", "path must be a non-empty string")
			return
		}
		value, ok := headless_config_value(state, string(path), context.temp_allocator)
		if !ok {
			headless_write_error(request, "unknown_config_path", "unknown config path")
			return
		}
		object := headless_base_event("config", request, context.temp_allocator)
		headless_object_set(&object, "ok", json.Boolean(true), context.temp_allocator)
		headless_object_set(
			&object,
			"path",
			headless_string_value(string(path), context.temp_allocator),
			context.temp_allocator,
		)
		headless_object_set(&object, "value", value, context.temp_allocator)
		headless_write_json_object(object)
		return
	}

	object := headless_base_event("config", request, context.temp_allocator)
	headless_object_set(&object, "ok", json.Boolean(true), context.temp_allocator)
	headless_object_set(
		&object,
		"value",
		headless_config_snapshot(state, context.temp_allocator),
		context.temp_allocator,
	)
	headless_write_json_object(object)
}

headless_handle_set_config :: proc(state: ^App_State, request: ^Headless_Request) {
	pathValue, hasPath := request.object["path"]
	if !hasPath {
		headless_write_error(request, "invalid_request", "missing path")
		return
	}
	path, pathOK := pathValue.(json.String)
	if !pathOK || string(path) == "" {
		headless_write_error(request, "invalid_request", "path must be a non-empty string")
		return
	}
	value, hasValue := request.object["value"]
	if !hasValue {
		headless_write_error(request, "invalid_request", "missing value")
		return
	}
	persist := false
	if persistValue, hasPersist := request.object["persist"]; hasPersist {
		persistBool, persistOK := persistValue.(json.Boolean)
		if !persistOK {
			headless_write_error(request, "invalid_request", "persist must be a boolean")
			return
		}
		persist = bool(persistBool)
	}

	if !headless_set_config_value(state, string(path), value) {
		headless_write_error(request, "invalid_config_value", "unknown path or invalid value")
		return
	}

	if persist {
		if state.configHome == "" {
			headless_write_error(
				request,
				"config_persist_failed",
				"cannot persist without a config home",
			)
			return
		}
		if settings.save_config_to_file(state.configHome, state.config) != .None {
			headless_write_error(request, "config_persist_failed", "failed to save config")
			return
		}
	}

	headless_apply_config_change(state, persist)
	headless_write_ack(request, state)
}

headless_handle_send_message :: proc(state: ^App_State, request: ^Headless_Request) {
	textValue, hasText := request.object["text"]
	if !hasText {
		headless_write_error(request, "invalid_request", "missing text")
		return
	}
	text, textOK := textValue.(json.String)
	if !textOK {
		headless_write_error(request, "invalid_request", "text must be a string")
		return
	}
	text_input.input_buffer_set_text(&state.input, string(text))
	app_submit_input(state)
	headless_poll_once(state)
	headless_write_ack(request, state)
}

headless_handle_key :: proc(state: ^App_State, request: ^Headless_Request) {
	byteValue, hasByte := request.object["byte"]
	if !hasByte {
		headless_write_error(request, "invalid_request", "missing byte")
		return
	}
	inputByte, byteOK := byteValue.(json.Integer)
	if !byteOK || inputByte < 0 || inputByte > 255 {
		headless_write_error(request, "invalid_request", "byte must be an integer from 0 to 255")
		return
	}
	_ = app_handle_input_byte(state, byte(inputByte))
	headless_poll_once(state)
	headless_write_ack(request, state)
}

headless_poll_once :: proc(state: ^App_State) {
	_ = app_poll_agent_host(state)
	_ = app_poll_tool_execution(state)
}

headless_wait_until_idle :: proc(state: ^App_State) {
	for spin := 0; spin < 1000; spin += 1 {
		wasDirty := app_poll_agent_host(state)
		wasDirty = app_poll_tool_execution(state) || wasDirty
		if !wasDirty && !app_agent_host_stream_active(state) && !state.toolExecution.active {
			break
		}
	}
}

headless_write_ack :: proc(request: ^Headless_Request, state: ^App_State) {
	headless_write_status("ack", request, state)
}

headless_write_status :: proc(kind: string, request: ^Headless_Request, state: ^App_State) {
	object := headless_base_event(kind, request, context.temp_allocator)
	headless_object_set(&object, "ok", json.Boolean(true), context.temp_allocator)
	headless_object_set(
		&object,
		"mode",
		headless_string_value(headless_mode_name(state), context.temp_allocator),
		context.temp_allocator,
	)
	headless_object_set(
		&object,
		"status",
		headless_string_value(state.status, context.temp_allocator),
		context.temp_allocator,
	)
	headless_object_set(
		&object,
		"streamActive",
		json.Boolean(app_agent_host_stream_active(state)),
		context.temp_allocator,
	)
	headless_object_set(
		&object,
		"toolActive",
		json.Boolean(state.toolExecution.active),
		context.temp_allocator,
	)
	headless_write_json_object(object)
}

headless_write_error :: proc(request: ^Headless_Request, code: string, message: string) {
	object := headless_base_event("error", request, context.temp_allocator)
	headless_object_set(&object, "ok", json.Boolean(false), context.temp_allocator)
	headless_object_set(
		&object,
		"code",
		headless_string_value(code, context.temp_allocator),
		context.temp_allocator,
	)
	headless_object_set(
		&object,
		"message",
		headless_string_value(message, context.temp_allocator),
		context.temp_allocator,
	)
	headless_write_json_object(object)
}

headless_write_history :: proc(request: ^Headless_Request, state: ^App_State) {
	object := headless_base_event("history", request, context.temp_allocator)
	headless_object_set(&object, "ok", json.Boolean(true), context.temp_allocator)

	entries := make([dynamic]json.Value, 0, len(state.history), context.temp_allocator)
	for entry in state.history {
		entryObject := json.Object(make(map[string]json.Value, 2, context.temp_allocator))
		headless_object_set(
			&entryObject,
			"role",
			headless_string_value(headless_history_role_name(entry.role), context.temp_allocator),
			context.temp_allocator,
		)
		headless_object_set(
			&entryObject,
			"content",
			headless_string_value(entry.content, context.temp_allocator),
			context.temp_allocator,
		)
		append(&entries, json.Value(entryObject))
	}
	headless_object_set(&object, "entries", json.Array(entries), context.temp_allocator)
	headless_write_json_object(object)
}

headless_config_snapshot :: proc(state: ^App_State, allocator := context.allocator) -> json.Value {
	object := json.Object(make(map[string]json.Value, 11, allocator))
	headless_object_set(
		&object,
		"selectedProvider",
		headless_string_value(state.config.selectedProvider, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"selectedModel",
		headless_string_value(state.config.selectedModel, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"embeddingProvider",
		headless_string_value(state.config.embeddingProvider, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"embeddingModel",
		headless_string_value(state.config.embeddingModel, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"safetyProvider",
		headless_string_value(state.config.safetyProvider, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"safetyModel",
		headless_string_value(state.config.safetyModel, allocator),
		allocator,
	)
	headless_object_set(
		&object,
		"approvalMethod",
		headless_string_value(
			settings.approval_method_to_string(state.config.approvalMethod),
			allocator,
		),
		allocator,
	)
	headless_object_set(
		&object,
		"toolContinuations",
		json.Integer(i64(state.config.toolContinuations)),
		allocator,
	)
	headless_object_set(
		&object,
		"maxSubagentDepth",
		json.Integer(i64(state.config.maxSubagentDepth)),
		allocator,
	)
	headless_object_set(
		&object,
		"maxSubagentsPerSession",
		json.Integer(i64(state.config.maxSubagentsPerSession)),
		allocator,
	)
	headless_object_set(
		&object,
		"systemPromptMode",
		headless_string_value(
			settings.system_prompt_mode_to_string(state.config.systemPromptMode),
			allocator,
		),
		allocator,
	)
	return json.Value(object)
}

headless_config_value :: proc(
	state: ^App_State,
	path: string,
	allocator := context.allocator,
) -> (
	json.Value,
	bool,
) {
	switch path {
	case "selectedProvider":
		return headless_string_value(state.config.selectedProvider, allocator), true
	case "selectedModel":
		return headless_string_value(state.config.selectedModel, allocator), true
	case "embeddingProvider":
		return headless_string_value(state.config.embeddingProvider, allocator), true
	case "embeddingModel":
		return headless_string_value(state.config.embeddingModel, allocator), true
	case "safetyProvider":
		return headless_string_value(state.config.safetyProvider, allocator), true
	case "safetyModel":
		return headless_string_value(state.config.safetyModel, allocator), true
	case "approvalMethod":
		return headless_string_value(
				settings.approval_method_to_string(state.config.approvalMethod),
				allocator,
			),
			true
	case "toolContinuations":
		return json.Integer(i64(state.config.toolContinuations)), true
	case "maxSubagentDepth":
		return json.Integer(i64(state.config.maxSubagentDepth)), true
	case "maxSubagentsPerSession":
		return json.Integer(i64(state.config.maxSubagentsPerSession)), true
	case "systemPromptMode":
		return headless_string_value(
				settings.system_prompt_mode_to_string(state.config.systemPromptMode),
				allocator,
			),
			true
	}
	return nil, false
}

headless_set_config_value :: proc(state: ^App_State, path: string, value: json.Value) -> bool {
	switch path {
	case "selectedProvider":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.selectedProvider,
			&state.modelProviderOwned,
			string(text),
		)
		return true
	case "selectedModel":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.selectedModel,
			&state.modelNameOwned,
			string(text),
		)
		return true
	case "embeddingProvider":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.embeddingProvider,
			&state.embeddingProviderOwned,
			string(text),
		)
		return true
	case "embeddingModel":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.embeddingModel,
			&state.embeddingModelOwned,
			string(text),
		)
		return true
	case "safetyProvider":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.safetyProvider,
			&state.safetyProviderOwned,
			string(text),
		)
		return true
	case "safetyModel":
		text, ok := value.(json.String)
		if !ok {return false}
		headless_set_owned_config_string(
			state,
			&state.config.safetyModel,
			&state.safetyModelOwned,
			string(text),
		)
		return true
	case "approvalMethod":
		text, ok := value.(json.String)
		if !ok {return false}
		method, methodOK := settings.approval_method_from_string(string(text))
		if !methodOK {return false}
		state.config.approvalMethod = method
		return true
	case "toolContinuations":
		integer, ok := value.(json.Integer)
		if !ok || integer < 0 {return false}
		state.config.toolContinuations = int(integer)
		return true
	case "maxSubagentDepth":
		integer, ok := value.(json.Integer)
		if !ok || integer < 0 {return false}
		state.config.maxSubagentDepth = int(integer)
		return true
	case "maxSubagentsPerSession":
		integer, ok := value.(json.Integer)
		if !ok || integer < 0 {return false}
		state.config.maxSubagentsPerSession = int(integer)
		return true
	case "systemPromptMode":
		text, ok := value.(json.String)
		if !ok {return false}
		mode, modeOK := settings.system_prompt_mode_from_string(string(text))
		if !modeOK {return false}
		state.config.systemPromptMode = mode
		return true
	}
	return false
}

headless_set_owned_config_string :: proc(
	state: ^App_State,
	field: ^string,
	owned: ^bool,
	value: string,
) {
	if owned^ && field^ != "" {
		delete(field^, context.allocator)
	}
	field^ = strings.clone(value, context.allocator)
	owned^ = true
}

headless_apply_config_change :: proc(state: ^App_State, persisted: bool) {
	ai.clear_interfaces()
	app_register_config_interfaces(state.config, false, context.allocator)
	app_rebuild_model_entries(state, context.allocator)
	app_rebuild_code_index(state, context.allocator)
	if persisted {
		state.status = "Config changed and saved"
	} else {
		state.status = "Config changed"
	}
}

headless_write_json_object :: proc(object: json.Object) {
	line, ok := headless_encode_event(object, context.temp_allocator)
	if !ok {
		fmt.eprintln("headless: failed to encode JSON response")
		return
	}
	defer delete(line, context.temp_allocator)
	payload := strings.concatenate({line, "\n"}, context.temp_allocator)
	defer delete(payload, context.temp_allocator)
	remaining := transmute([]byte)payload
	for len(remaining) > 0 {
		written, writeErr := os.write(os.stdout, remaining)
		if writeErr != nil || written <= 0 {
			fmt.eprintln("headless: failed to write JSON response")
			return
		}
		remaining = remaining[written:]
	}
}

// headless_mode_name reports the top-most overlay if one is active,
// otherwise the current full-screen App_Screen. Breaking change from the
// old App_Mode names is acceptable per this alpha-stage project.
headless_mode_name :: proc(state: ^App_State) -> string {
	if top := app_top_overlay(state); top != nil {
		switch _ in top^ {
		case Config_Overlay:
			return "config"
		case Approval_Overlay:
			return "approval"
		case widgets.Context_Menu:
			return "context_menu"
		case widgets.Dropdown_List:
			return "dropdown_list"
		}
	}
	switch state.screen {
	case .Chat:
		return "chat"
	case .Setup:
		return "setup"
	}
	return "unknown"
}

headless_history_role_name :: proc(role: History_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	case .Subagent:
		return "subagent"
	case .Note:
		return "note"
	}
	return "unknown"
}
