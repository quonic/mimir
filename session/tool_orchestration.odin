#+vet explicit-allocators
package session

import "../agent"
import "../ai"
import "../builtin_tools"
import "../code_index"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import "../settings"
import "../tool_policy"

MAX_RETAINED_TOOL_OUTPUT_BYTES :: 64 * 1024
// A file diff is left out when the old or the new text is larger than this.
MAX_FILE_DIFF_BYTES :: 1024 * 1024
SEARCH_CODE_DEFAULT_MAX_RESULTS :: 5
SEARCH_CODE_MAX_RESULTS :: 10

// What a tool call can use while it runs on the worker thread. The session does not change
// these while the tool runs.
Tool_Execution_Context :: struct {
	dispatcher:      ^tool_policy.Tool_Dispatcher,
	skills:          ^settings.Skill_Registry,
	// nil when no code index is configured.
	codeIndex:       ^code_index.Code_Index,
	// The embedding client that search_code uses, or the error from creating it.
	embeddingClient: ai.Client,
	embeddingError:  ai.AI_Error,
}

Tool_Execution_State :: struct {
	mutex:          sync.Mutex,
	allocator:      mem.Allocator,
	worker:         ^thread.Thread,
	toolContext:    Tool_Execution_Context,
	call:           tool_policy.Tool_Call,
	result:         string,
	resultOwned:    bool,
	agentID:        agent.Agent_ID,
	agentRequestID: string,
	// The file change of the call, for the tools that change one file. Owned by allocator.
	diff:           File_Diff,
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
	search_string:     string,
	max_results:       int,
	name:              string,
	resource:          string,
	task:              string,
	tools:             []string,
	depth:             int,
}

tool_definitions_for_provider :: proc(
	providerType: ai.Interface_Type,
	allocator := context.allocator,
) -> [dynamic]ai.Tool_Definition {
	if providerType == .None {
		return make([dynamic]ai.Tool_Definition, 0, 0, allocator)
	}
	definitions := builtin_tools.builtin_ai_tool_definitions(allocator)
	return definitions
}

tool_execution_destroy :: proc(execution: ^Tool_Execution_State) {
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
	file_diff_destroy(&execution.diff, execution.allocator)
	execution^ = {}
}

session_start_agent_tool_execution :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	if agent.agent_id_is_none(agentID) || requestID == "" {
		return false
	}
	runtime := &session.host.runtime
	if agent.runtime_resolve_tool(runtime, agentID, requestID, .Allowed, "") != .None {
		return false
	}
	started := session_start_tool_execution_for_agent(session, call, agentID, requestID)
	if !started {
		_ = agent.runtime_finish_tool(runtime, agentID, "Tool call could not start.", true)
	}
	return started
}

session_start_tool_execution_for_agent :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	execution := &session.toolExecution
	if execution.active || call.id == "" {
		return false
	}
	execution.toolContext = session_tool_execution_context(session, call)
	execution.call = tool_policy.tool_call_clone(call, execution.allocator)
	execution.agentID = agentID
	execution.agentRequestID = strings.clone(requestID, execution.allocator)
	execution.active = true
	execution.finished = false
	execution.worker = thread.create(tool_execution_worker_proc)
	execution.worker.data = rawptr(execution)
	thread.start(execution.worker)
	session_emit_notice(session, "Tool call running")
	return true
}

// Collects what the tool call uses on the worker thread. Runs on the thread of the session.
session_tool_execution_context :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
) -> Tool_Execution_Context {
	toolContext := Tool_Execution_Context {
		dispatcher     = &session.dispatcher,
		skills         = &session.skills,
		embeddingError = .Invalid_Request,
	}
	if call.id == "search_code" {
		if !session.codeIndexReady {
			session_rebuild_code_index(session)
		}
		toolContext.embeddingClient, toolContext.embeddingError = session_embedding_client(
			session.config,
		)
	}
	if session.codeIndexReady {
		toolContext.codeIndex = &session.codeIndex
	}
	return toolContext
}

tool_execution_worker_proc :: proc(workerThread: ^thread.Thread) {
	execution := cast(^Tool_Execution_State)workerThread.data
	diffPath, diffOldText, diffNewFile, diffOK := file_diff_begin(
		execution.toolContext,
		execution.call,
		execution.allocator,
	)
	output := execute_tool_call(execution.toolContext, execution.call)
	diff: File_Diff
	if diffOK {
		diff = file_diff_end(
			diffPath,
			diffOldText,
			diffNewFile,
			!tool_output_is_error(output),
			execution.allocator,
		)
	}
	outputOwned := tool_output_is_owned(execution.call.id)
	if outputOwned {
		ownedOutput := strings.clone(output, execution.allocator)
		if execution.call.id == "search_code" || execution.call.id == "find_code" {
			delete(output, execution.toolContext.dispatcher.allocator)
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
		execution.diff = diff
		execution.finished = true
	}
}

session_poll_tool_execution :: proc(session: ^Session) -> bool {
	execution := &session.toolExecution
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
	isError := tool_output_is_error(output)
	toolStatus := Tool_Call_Status.Completed
	if isError {
		toolStatus = .Failed
	}
	session_emit_tool_call_updated(
		session,
		execution.call.callID,
		toolStatus,
		output,
		execution.diff,
	)
	file_diff_destroy(&execution.diff, execution.allocator)
	if !agent.agent_id_is_none(agentID) && agentRequestID != "" {
		_ = agent.runtime_finish_tool(&session.host.runtime, agentID, output, isError)
	}
	destroy_tool_output_if_owned(output, outputOwned, execution.allocator)
	tool_policy.tool_call_destroy(&execution.call, execution.allocator)
	delete(execution.agentRequestID, execution.allocator)
	execution.call = {}
	execution.result = ""
	execution.resultOwned = false
	execution.toolContext = {}
	execution.agentID = agent.Agent_ID(0)
	execution.agentRequestID = ""
	execution.active = false
	execution.finished = false
	if isError {
		session_emit_notice(session, "Tool call failed", .Warning)
	} else {
		session_emit_notice(session, "Tool call completed")
	}
	if session.skillSettingsPending {
		session_apply_skill_settings(session)
	}
	if session.codeIndexRebuildPending {
		session_rebuild_code_index(session)
	}
	return true
}

// Reports whether the tool changes one file, so its update can carry a File_Diff.
tool_changes_one_file :: proc(toolID: string) -> bool {
	switch toolID {
	case builtin_tools.TOOL_WRITE_FILE,
	     builtin_tools.TOOL_PATCH_FILE,
	     builtin_tools.TOOL_REPLACE_STRING_IN_FILE:
		return true
	}
	return false
}

// Reads the file of a call that changes one file, before the call runs. It returns false when
// the call changes no file, the path is outside the project, or the file is too large or not
// UTF-8 text. Runs on the tool worker.
file_diff_begin :: proc(
	toolContext: Tool_Execution_Context,
	call: tool_policy.Tool_Call,
	allocator: mem.Allocator,
) -> (
	path: string,
	oldText: string,
	newFile: bool,
	ok: bool,
) {
	if !tool_changes_one_file(call.id) || toolContext.dispatcher == nil {
		return
	}
	resolved, resolvedOK := tool_policy.permission_resolve_project_path(
		toolContext.dispatcher.projectRoot,
		call.filePath,
		allocator,
	)
	if !resolvedOK {
		return
	}
	if !os.exists(resolved) {
		return resolved, "", true, true
	}
	text, textOK := file_diff_read_text(resolved, allocator)
	if !textOK {
		delete(resolved, allocator)
		return
	}
	return resolved, text, false, true
}

// Builds the File_Diff of a call from file_diff_begin, after the call ran. It takes ownership
// of path and oldText. When the call failed or the new text cannot be read, it frees them and
// returns an empty diff.
file_diff_end :: proc(
	path, oldText: string,
	newFile, succeeded: bool,
	allocator: mem.Allocator,
) -> File_Diff {
	newText, newTextOK := "", false
	if succeeded {
		newText, newTextOK = file_diff_read_text(path, allocator)
	}
	if !newTextOK {
		delete(path, allocator)
		delete(oldText, allocator)
		return File_Diff{}
	}
	return File_Diff{path = path, newFile = newFile, oldText = oldText, newText = newText}
}

// Reads a file as text for a File_Diff. It fails for a file larger than MAX_FILE_DIFF_BYTES or
// one that is not UTF-8.
file_diff_read_text :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
	info, statErr := os.stat(path, allocator)
	if statErr != nil {
		return "", false
	}
	size := info.size
	os.file_info_delete(info, allocator)
	if size > MAX_FILE_DIFF_BYTES {
		return "", false
	}
	data, readErr := os.read_entire_file_from_path(path, allocator)
	if readErr != nil {
		return "", false
	}
	if len(data) > MAX_FILE_DIFF_BYTES || !utf8.valid_string(string(data)) {
		delete(data, allocator)
		return "", false
	}
	return string(data), true
}

tool_output_is_error :: proc(output: string) -> bool {
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

tool_call_from_ai :: proc(
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
	if call.id == builtin_tools.TOOL_GREP_SEARCH {
		delete(call.query, allocator)
		call.query = strings.clone(arguments.search_string, allocator)
		if call.filePath == "" || call.query == "" || call.maxResults < 0 {
			tool_policy.tool_call_destroy(&call, allocator)
			return tool_policy.Tool_Call{}, false
		}
		if call.maxResults == 0 {
			call.maxResults = builtin_tools.GREP_SEARCH_DEFAULT_MAX_RESULTS
		} else if call.maxResults > builtin_tools.GREP_SEARCH_MAX_RESULTS {
			call.maxResults = builtin_tools.GREP_SEARCH_MAX_RESULTS
		}
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

// Runs a tool call on the worker thread. It uses only what toolContext gives it.
execute_tool_call :: proc(
	toolContext: Tool_Execution_Context,
	call: tool_policy.Tool_Call,
) -> string {
	dispatcher := toolContext.dispatcher
	if call.id == builtin_tools.TOOL_READ_SKILL {
		if call.content != "" {
			result, ok := settings.skill_registry_read_resource(
				toolContext.skills,
				call.query,
				call.content,
			)
			if !ok {
				return strings.concatenate(
					{"Error reading skill resource: ", result},
					dispatcher.allocator,
				)
			}
			return result
		}
		result, ok := settings.skill_registry_read(toolContext.skills, call.query)
		if !ok {
			return strings.concatenate({"Error reading skill: ", result}, dispatcher.allocator)
		}
		return result
	}
	if call.id != "search_code" && call.id != "find_code" {
		return builtin_tools.execute_builtin_tool(dispatcher, call)
	}
	if call.id == "find_code" {
		results := find_code(
			dispatcher.projectRoot,
			call.query,
			call.maxResults,
			dispatcher.allocator,
		)
		defer code_index.code_index_search_results_destroy(&results, dispatcher.allocator)
		index := code_index.Code_Index {
			projectRoot = dispatcher.projectRoot,
		}
		return search_code_results_json(&index, results[:], dispatcher.allocator)
	}
	results, searchError := search_code(
		toolContext,
		call.query,
		call.maxResults,
		dispatcher.allocator,
	)
	if searchError != .None {
		return strings.concatenate(
			{"search_code: ", assistant_stream_error_text(searchError)},
			dispatcher.allocator,
		)
	}
	defer code_index.code_index_search_results_destroy(&results, dispatcher.allocator)
	return search_code_results_json(toolContext.codeIndex, results[:], dispatcher.allocator)
}

// Builds the embedding database of the code index when it has none yet.
ensure_code_index :: proc(
	toolContext: Tool_Execution_Context,
	allocator := context.allocator,
) -> ai.AI_Error {
	if toolContext.codeIndex == nil {
		return .Invalid_Request
	}
	if toolContext.codeIndex.databaseInitialized {
		return .None
	}
	if toolContext.embeddingError != .None {
		return toolContext.embeddingError
	}
	rebuildError := code_index.code_index_rebuild(
		toolContext.codeIndex,
		toolContext.embeddingClient,
		code_index.CODE_INDEX_DEFAULT_CHUNK_LINES,
		code_index.CODE_INDEX_DEFAULT_CHUNK_OVERLAP_LINES,
		allocator,
	)
	if rebuildError != .None {
		return rebuildError
	}
	if code_index.code_index_save(toolContext.codeIndex) != .None {
		return .Provider_Error
	}
	return .None
}

search_code :: proc(
	toolContext: Tool_Execution_Context,
	query: string,
	maximumResults: int,
	allocator := context.allocator,
) -> (
	[dynamic]code_index.Code_Search_Result,
	ai.AI_Error,
) {
	results := make([dynamic]code_index.Code_Search_Result, 0, 0, allocator)
	ensureError := ensure_code_index(toolContext, allocator)
	if ensureError != .None {
		return results, ensureError
	}
	if toolContext.embeddingError != .None {
		return results, toolContext.embeddingError
	}
	delete(results)
	return code_index.code_index_search_text(
		toolContext.codeIndex,
		toolContext.embeddingClient,
		query,
		maximumResults,
		allocator,
	)
}

find_code :: proc(
	projectRoot: string,
	query: string,
	maximumResults: int,
	allocator := context.allocator,
) -> [dynamic]code_index.Code_Search_Result {
	results := make([dynamic]code_index.Code_Search_Result, 0, 0, allocator)
	if projectRoot == "" {
		return results
	}
	delete(results)
	index := code_index.Code_Index {
		projectRoot = projectRoot,
	}
	return code_index.code_index_find_text(&index, query, maximumResults, allocator)
}

search_code_results_json :: proc(
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

tool_output_is_owned :: proc(toolID: string) -> bool {
	switch toolID {
	case "read_file",
	     "read_skill",
	     "write_file",
	     "patch_file",
	     "grep_search",
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

destroy_tool_output_if_owned :: proc(output: string, owned: bool, allocator: mem.Allocator) {
	if owned {
		delete(output, allocator)
	}
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
