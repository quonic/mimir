#+vet explicit-allocators
package main

import "agent"
import "ai"
import "builtin_tools"
import "code_index"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "settings"
import "tool_policy"

MAX_RETAINED_TOOL_OUTPUT_BYTES :: 64 * 1024
SEARCH_CODE_DEFAULT_MAX_RESULTS :: 5
SEARCH_CODE_MAX_RESULTS :: 10
SPINNER_FRAMES :: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

Tool_Execution_State :: struct {
	mutex:          sync.Mutex,
	allocator:      mem.Allocator,
	worker:         ^thread.Thread,
	app:            ^App_State,
	call:           tool_policy.Tool_Call,
	result:         string,
	resultOwned:    bool,
	historyIndex:   int,
	agentID:        agent.Agent_ID,
	agentRequestID: string,
	active:         bool,
	finished:       bool,
}
AI_Tool_Call_Arguments :: struct {
	file_path:         string,
	directory_path:    string,
	content:           string,
	patch_content:     string,
	overwrite:         string,
	command:           string,
	working_directory: string,
	timeout:           int,
	query:             string,
	max_results:       int,
	name:              string,
	resource:          string,
	task:              string,
	tools:             []string,
	depth:             int,
}

app_tool_definitions_for_provider :: proc(
	state: ^App_State,
	providerType: ai.Interface_Type,
	allocator := context.allocator,
) -> [dynamic]ai.Tool_Definition {
	if providerType == .None {
		return make([dynamic]ai.Tool_Definition, 0, 0, allocator)
	}
	definitions := builtin_tools.builtin_ai_tool_definitions(allocator)
	return definitions
}
app_destroy_tool_execution :: proc(execution: ^Tool_Execution_State) {
	if execution.worker != nil {
		thread.join(execution.worker)
		thread.destroy(execution.worker)
		execution.worker = nil
	}
	if execution.call.id != "" {
		tool_policy.tool_call_destroy(&execution.call, execution.allocator)
	}
	if execution.resultOwned {
		delete(execution.result, execution.allocator)
	}
	delete(execution.agentRequestID, execution.allocator)
	execution^ = {}
}

app_build_ai_messages :: proc(
	history: []History_Entry,
	systemPrompt: string,
	allocator := context.allocator,
) -> [dynamic]ai.Message {
	messages := make([dynamic]ai.Message, 0, len(history) + 1, allocator)
	if systemPrompt != "" {
		append(
			&messages,
			ai.Message{role = .System, content = strings.clone(systemPrompt, allocator)},
		)
	}
	for entry in history {
		if entry.content == "" {
			continue
		}
		if entry.role == .System {
			continue
		}

		role, ok := app_ai_role_from_history_role(entry.role)
		if !ok {
			continue
		}

		append(
			&messages,
			ai.Message{role = role, content = strings.clone(entry.content, allocator)},
		)
	}
	return messages
}

app_start_agent_tool_execution :: proc(
	state: ^App_State,
	call: tool_policy.Tool_Call,
	historyIndex: int,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	if agent.agent_id_is_none(agentID) || requestID == "" {
		return false
	}
	if agent.runtime_resolve_tool(&state.agentHost.runtime, agentID, requestID, .Allowed, "") !=
	   .None {
		return false
	}
	started := app_start_tool_execution_for_agent(state, call, historyIndex, agentID, requestID)
	if !started {
		_ = agent.runtime_finish_tool(
			&state.agentHost.runtime,
			agentID,
			"Tool call could not start.",
			true,
		)
	}
	return started
}

app_start_tool_execution_for_agent :: proc(
	state: ^App_State,
	call: tool_policy.Tool_Call,
	historyIndex: int,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	execution := &state.toolExecution
	if execution.active || call.id == "" {
		return false
	}
	execution.app = state
	execution.call = tool_policy.tool_call_clone(call, execution.allocator)
	execution.historyIndex = historyIndex
	execution.agentID = agentID
	execution.agentRequestID = strings.clone(requestID, execution.allocator)
	execution.active = true
	execution.finished = false
	execution.worker = thread.create(tool_execution_worker_proc)
	execution.worker.data = rawptr(execution)
	thread.start(execution.worker)
	state.status = "Tool call running"
	return true
}

tool_execution_worker_proc :: proc(workerThread: ^thread.Thread) {
	execution := cast(^Tool_Execution_State)workerThread.data
	output := app_execute_tool_call(execution.app, execution.call)
	outputOwned := app_tool_output_is_owned(execution.call.id)
	if outputOwned {
		ownedOutput := strings.clone(output, execution.allocator)
		if execution.call.id == "search_code" || execution.call.id == "find_code" {
			delete(output, execution.app.dispatcher.allocator)
		} else {
			delete(output, context.allocator)
		}
		output = ownedOutput
	}
	if len(output) > MAX_RETAINED_TOOL_OUTPUT_BYTES {
		truncatedOutput := strings.concatenate(
			{output[:MAX_RETAINED_TOOL_OUTPUT_BYTES], "\n\n[Tool output truncated after 64 KiB.]"},
			execution.allocator,
		)
		delete(output, execution.allocator)
		output = truncatedOutput
		outputOwned = true
	}
	if sync.mutex_guard(&execution.mutex) {
		execution.result = output
		execution.resultOwned = outputOwned
		execution.finished = true
	}
}

app_poll_tool_execution :: proc(state: ^App_State) -> bool {
	execution := &state.toolExecution
	if !execution.active || execution.worker == nil || !thread.is_done(execution.worker) {
		return false
	}

	thread.join(execution.worker)
	thread.destroy(execution.worker)
	execution.worker = nil
	output := execution.result
	outputOwned := execution.resultOwned
	agentID := execution.agentID
	agentRequestID := execution.agentRequestID
	isError := app_tool_output_is_error(output)
	if isError {
		app_update_tool_history(state, execution.historyIndex, execution.call, "failed")
	} else {
		app_update_tool_history(state, execution.historyIndex, execution.call, "completed")
	}
	if !agent.agent_id_is_none(agentID) && agentRequestID != "" {
		_ = agent.runtime_finish_tool(&state.agentHost.runtime, agentID, output, isError)
	}
	app_destroy_tool_output_if_owned(output, outputOwned, execution.allocator)
	tool_policy.tool_call_destroy(&execution.call, execution.allocator)
	delete(execution.agentRequestID, execution.allocator)
	execution.call = {}
	execution.result = ""
	execution.resultOwned = false
	execution.app = nil
	execution.historyIndex = -1
	execution.agentID = agent.Agent_ID(0)
	execution.agentRequestID = ""
	execution.active = false
	execution.finished = false
	if isError {
		state.status = "Tool call failed"
	} else {
		state.status = "Tool call completed"
	}
	return true
}

app_tool_output_is_error :: proc(output: string) -> bool {
	return(
		strings.starts_with(output, "Error ") ||
		strings.contains(output, ": Error ") ||
		strings.contains(output, ": Unsupported ") ||
		strings.contains(output, ": Command exited ") ||
		strings.starts_with(output, "File already exists.") ||
		strings.starts_with(output, "Invalid value for overwrite:") ||
		output == "Permission denied." ||
		output == "Permission approval required." \
	)
}

app_tool_call_from_ai :: proc(
	aiCall: ai.Tool_Call,
	allocator := context.allocator,
) -> (
	tool_policy.Tool_Call,
	bool,
) {
	if aiCall.name == "" || aiCall.arguments == "" {
		return tool_policy.Tool_Call{}, false
	}

	arguments: AI_Tool_Call_Arguments
	decodeErr := json.unmarshal_string(
		aiCall.arguments,
		&arguments,
		allocator = context.temp_allocator,
	)
	if decodeErr != nil {
		return tool_policy.Tool_Call{}, false
	}

	call := tool_policy.Tool_Call {
		callID           = strings.clone(aiCall.id, allocator),
		id               = strings.clone(aiCall.name, allocator),
		filePath         = strings.clone(arguments.file_path, allocator),
		directoryPath    = strings.clone(arguments.directory_path, allocator),
		content          = strings.clone(arguments.content, allocator),
		patchContent     = strings.clone(arguments.patch_content, allocator),
		overwrite        = strings.clone(arguments.overwrite, allocator),
		command          = strings.clone(arguments.command, allocator),
		workingDirectory = strings.clone(arguments.working_directory, allocator),
		timeout          = arguments.timeout,
		query            = strings.clone(arguments.query, allocator),
		maxResults       = arguments.max_results,
		task             = strings.clone(arguments.task, allocator),
		subagentDepth    = arguments.depth,
	}
	if call.id == builtin_tools.TOOL_READ_SKILL {
		delete(call.query, allocator)
		call.query = strings.clone(arguments.name, allocator)
		delete(call.content, allocator)
		call.content = strings.clone(arguments.resource, allocator)
		if call.query == "" {
			tool_policy.tool_call_destroy(&call, allocator)
			return tool_policy.Tool_Call{}, false
		}
	}
	if call.id == builtin_tools.TOOL_PATCH_FILE &&
	   (call.filePath == "" || call.patchContent == "") {
		tool_policy.tool_call_destroy(&call, allocator)
		return tool_policy.Tool_Call{}, false
	}
	if call.id == "search_code" || call.id == "find_code" {
		if call.query == "" || call.maxResults < 0 {
			tool_policy.tool_call_destroy(&call, allocator)
			return tool_policy.Tool_Call{}, false
		}
		if call.maxResults == 0 {
			call.maxResults = SEARCH_CODE_DEFAULT_MAX_RESULTS
		} else if call.maxResults > SEARCH_CODE_MAX_RESULTS {
			call.maxResults = SEARCH_CODE_MAX_RESULTS
		}
	}
	if call.id == "run_subagent" {
		if call.task == "" || len(arguments.tools) == 0 {
			tool_policy.tool_call_destroy(&call, allocator)
			return tool_policy.Tool_Call{}, false
		}
		toolsJSON, marshalErr := json.marshal(arguments.tools, allocator = allocator)
		if marshalErr != nil {
			tool_policy.tool_call_destroy(&call, allocator)
			return tool_policy.Tool_Call{}, false
		}
		call.subagentToolsJSON = string(toolsJSON)
	}
	return call, true
}

app_execute_tool_call :: proc(state: ^App_State, call: tool_policy.Tool_Call) -> string {
	if call.id == builtin_tools.TOOL_READ_SKILL {
		if call.content != "" {
			result, ok := settings.skill_registry_read_resource(
				&state.skills,
				call.query,
				call.content,
			)
			if !ok {
				return strings.concatenate(
					{"Error reading skill resource: ", result},
					state.dispatcher.allocator,
				)
			}
			return result
		}
		result, ok := settings.skill_registry_read(&state.skills, call.query)
		if !ok {
			return strings.concatenate(
				{"Error reading skill: ", result},
				state.dispatcher.allocator,
			)
		}
		return result
	}
	if call.id != "search_code" && call.id != "find_code" {
		return builtin_tools.execute_builtin_tool(&state.dispatcher, call)
	}
	if call.id == "find_code" {
		results := app_find_code(state, call.query, call.maxResults, state.dispatcher.allocator)
		defer code_index.code_index_search_results_destroy(&results, state.dispatcher.allocator)
		index := code_index.Code_Index {
			projectRoot = state.dispatcher.projectRoot,
		}
		return app_search_code_results_json(&index, results[:], state.dispatcher.allocator)
	}
	results, searchError := app_search_code(
		state,
		call.query,
		call.maxResults,
		state.dispatcher.allocator,
	)
	if searchError != .None {
		return strings.concatenate(
			{"search_code: ", assistant_stream_error_text(searchError)},
			state.dispatcher.allocator,
		)
	}
	defer code_index.code_index_search_results_destroy(&results, state.dispatcher.allocator)
	return app_search_code_results_json(&state.codeIndex, results[:], state.dispatcher.allocator)
}

app_search_code_results_json :: proc(
	codeIndex: ^code_index.Code_Index,
	results: []code_index.Code_Search_Result,
	allocator := context.allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, `{"results":[`)
	for result, index in results {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		location, locationOK := code_index.code_index_search_result_location(result)
		strings.write_string(&builder, `{"path":`)
		if locationOK {
			write_tool_json_string(&builder, location.relativePath)
		} else {
			write_tool_json_string(&builder, result.metadata)
		}
		strings.write_string(&builder, `,"start_line":`)
		if locationOK {
			write_decimal(&builder, location.startLine)
		} else {
			strings.write_byte(&builder, '0')
		}
		strings.write_string(&builder, `,"end_line":`)
		if locationOK {
			write_decimal(&builder, location.endLine)
		} else {
			strings.write_byte(&builder, '0')
		}
		excerpt := code_index.code_index_search_result_excerpt(
			codeIndex,
			result,
			allocator = allocator,
		)
		defer delete(excerpt, allocator)
		strings.write_string(&builder, `,"excerpt":`)
		write_tool_json_string(&builder, excerpt)
		strings.write_byte(&builder, '}')
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

write_tool_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	hex := "0123456789abcdef"
	for index := 0; index < len(text); index += 1 {
		b := text[index]
		switch b {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\b':
			strings.write_string(builder, "\\b")
		case '\f':
			strings.write_string(builder, "\\f")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			if b < 0x20 {
				strings.write_string(builder, "\\u00")
				strings.write_byte(builder, hex[int((b >> 4) & 0x0f)])
				strings.write_byte(builder, hex[int(b & 0x0f)])
			} else {
				strings.write_byte(builder, b)
			}
		}
	}
	strings.write_byte(builder, '"')
}

write_decimal :: proc(builder: ^strings.Builder, value: int) {
	if value == 0 {
		strings.write_byte(builder, '0')
		return
	}
	digits: [20]byte
	length := 0
	remaining := value
	for remaining > 0 {
		digits[length] = byte(remaining % 10) + '0'
		length += 1
		remaining /= 10
	}
	for index := length - 1; index >= 0; index -= 1 {
		strings.write_byte(builder, digits[index])
	}
}

app_ai_role_from_history_role :: proc(role: History_Role) -> (ai.Message_Role, bool) {
	switch role {
	case .System:
		return .System, true
	case .User:
		return .User, true
	case .Assistant:
		return .Assistant, true
	case .Tool:
		return .User, false
	case .Subagent:
		return .User, false
	case .Note:
		return .User, false
	}
	return .User, false
}
app_tool_output_is_owned :: proc(toolID: string) -> bool {
	switch toolID {
	case "read_file",
	     "read_skill",
	     "write_file",
	     "patch_file",
	     "list_directory",
	     "get_file_info",
	     "list_available_shells",
	     "run_in_terminal":
		return true
	case "search_code", "find_code":
		return true
	}
	return false
}

app_destroy_tool_output_if_owned :: proc(output: string, owned: bool, allocator: mem.Allocator) {
	if owned {
		delete(output, allocator)
	}
}

app_context_usage_status_text :: proc(
	state: ^App_State,
	allocator := context.temp_allocator,
) -> string {
	if state == nil {
		return ""
	}
	usage := state.agentHost.usage
	contextWindowTokens := state.agentHost.contextWindowTokens
	active := app_agent_host_stream_active(state)
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

assistant_stream_error_text :: proc(err: ai.AI_Error) -> string {
	switch err {
	case .None:
		return "Assistant response complete"
	case .Interface_Not_Found:
		return "Selected provider is not registered"
	case .Unsupported_Interface:
		return "Selected provider type is not supported"
	case .Unsupported_Model:
		return "Selected model is not supported"
	case .Invalid_Request:
		return "Assistant request is invalid"
	case .Invalid_Response:
		return "Provider returned an invalid response"
	case .Authentication_Error:
		return "Provider authentication failed"
	case .Rate_Limited:
		return "Provider rate limit reached"
	case .Server_Error:
		return "Provider server error"
	case .Network_Error:
		return "Provider network error"
	case .Provider_Error:
		return "Provider returned an error"
	}
	return "Assistant stream failed"
}
