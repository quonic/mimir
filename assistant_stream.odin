package main

import "ai"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MAX_TOOL_CONTINUATIONS :: 8
MAX_RETAINED_TOOL_OUTPUT_BYTES :: 64 * 1024
SEARCH_CODE_DEFAULT_MAX_RESULTS :: 5
SEARCH_CODE_MAX_RESULTS :: 10
SPINNER_FRAME_INTERVAL :: 100 * time.Millisecond
SPINNER_FRAMES :: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

Assistant_Stream_State :: struct {
	mutex:                   sync.Mutex,
	bufferAllocator:         mem.Allocator,
	worker:                  ^thread.Thread,
	workerData:              ^Assistant_Stream_Worker,
	assistantIndex:          int,
	partialBuffer:           [dynamic]byte,
	lastSyncedPartialLength: int,
	finishReason:            string,
	err:                     ai.AI_Error,
	active:                  bool,
	finished:                bool,
	cancelRequested:         bool,
	canceled:                bool,
	thinking:                bool,
	spinnerVisible:          bool,
	spinnerFrameIndex:       int,
	spinnerLastFrame:        time.Tick,
	toolCalls:               [dynamic]ai.Tool_Call,
	conversation:            [dynamic]ai.Message,
	continuationCount:       int,
	usage:                   ai.Chat_Usage,
	contextWindowTokens:     int,
	contextWindowCache:      [dynamic]Context_Window_Cache_Entry,
}

Tool_Execution_State :: struct {
	mutex:        sync.Mutex,
	allocator:    mem.Allocator,
	worker:       ^thread.Thread,
	app:          ^App_State,
	call:         Tool_Call,
	result:       string,
	resultOwned:  bool,
	historyIndex: int,
	active:       bool,
	finished:     bool,
}

Context_Window_Cache_Entry :: struct {
	providerName: string,
	model:        string,
	tokens:       int,
}

Spinner_Update :: struct {
	dirty:             bool,
	visibilityChanged: bool,
}

AI_Tool_Call_Arguments :: struct {
	file_path:         string,
	directory_path:    string,
	content:           string,
	overwrite:         string,
	command:           string,
	working_directory: string,
	timeout:           int,
	mcp_server:        string,
	query:             string,
	max_results:       int,
}

Assistant_Stream_Worker :: struct {
	stream:          ^Assistant_Stream_State,
	client:          ai.Client,
	request:         ai.Chat_Request,
	toolDefinitions: [dynamic]ai.Tool_Definition,
}

app_tool_definitions_for_provider :: proc(
	providerType: ai.Interface_Type,
	allocator := context.allocator,
) -> [dynamic]ai.Tool_Definition {
	if providerType == .None {
		return make([dynamic]ai.Tool_Definition, 0, 0, allocator)
	}
	return builtin_ai_tool_definitions(allocator)
}

app_assistant_stream_active :: proc(state: ^App_State) -> bool {
	return state.stream.active
}

app_start_assistant_stream :: proc(state: ^App_State) {
	if state.stream.active {
		state.status = "Assistant stream already active"
		return
	}

	providerName := state.config.selectedProvider
	if providerName == "" {
		app_append_assistant_stream_error(state, "No provider selected")
		return
	}

	provider, providerOk := app_find_provider(state.config, providerName)
	if !providerOk || !provider.enabled {
		app_append_assistant_stream_error(state, "Selected provider is unavailable")
		return
	}

	model := state.config.selectedModel
	if model == "" {
		model = provider.model
	}
	if model == "" {
		app_append_assistant_stream_error(state, "No model selected")
		return
	}

	client, clientErr := ai.new_client(provider.name, provider.apiKey)
	if clientErr != .None {
		app_append_assistant_stream_error(state, assistant_stream_error_text(clientErr))
		return
	}

	if len(state.stream.conversation) == 0 {
		state.stream.conversation = app_build_ai_messages(
			state.history[:],
			state.stream.bufferAllocator,
		)
	}
	if len(state.stream.conversation) == 0 {
		app_append_assistant_stream_error(state, "No chat messages to send")
		return
	}

	append_history(state, .Assistant, "")
	assistantIndex := len(state.history) - 1

	workerData := new(Assistant_Stream_Worker)
	workerData.stream = &state.stream
	workerData.client = client
	workerData.toolDefinitions = app_tool_definitions_for_provider(
		provider.type,
		context.allocator,
	)
	workerData.request = ai.Chat_Request {
		model       = strings.clone(model, context.allocator),
		messages    = state.stream.conversation[:],
		tools       = workerData.toolDefinitions[:],
		temperature = 0.2,
		maxTokens   = 4096,
	}

	app_reset_assistant_stream_state(&state.stream)
	state.stream.contextWindowTokens = config_context_window_tokens(
		&state.config,
		provider.name,
		model,
	)
	state.stream.workerData = workerData
	state.stream.assistantIndex = assistantIndex
	state.stream.active = true
	state.stream.worker = thread.create(assistant_stream_worker_proc)
	state.stream.worker.data = rawptr(workerData)
	thread.start(state.stream.worker)
	state.status = "Streaming assistant response"
}

app_poll_assistant_stream :: proc(state: ^App_State) -> bool {
	if !state.stream.active {
		return app_process_pending_stream_tool_calls(state)
	}

	dirty := app_sync_assistant_history_entry(state)
	if dirty {
		state.historyRenderOnly = true
	}
	spinnerUpdate := app_update_assistant_stream_spinner(&state.stream)
	if spinnerUpdate.dirty {
		dirty = true
		state.historyRenderOnly = true
		if spinnerUpdate.visibilityChanged {
			app_invalidate_assistant_stream_history_entry(state)
		}
	}
	if state.stream.worker != nil && thread.is_done(state.stream.worker) {
		thread.join(state.stream.worker)
		thread.destroy(state.stream.worker)
		state.stream.worker = nil

		if state.stream.workerData != nil {
			app_destroy_assistant_stream_worker(state.stream.workerData)
			free(state.stream.workerData)
			state.stream.workerData = nil
		}

		if sync.mutex_guard(&state.stream.mutex) {
			switch {
			case state.stream.canceled:
				state.status = "Assistant stream canceled"
			case state.stream.err != .None:
				errorText := assistant_stream_error_text(state.stream.err)
				if len(state.stream.partialBuffer) > 0 {
					assistant_stream_append_partial(&state.stream, "\n\n")
				}
				assistant_stream_append_partial(&state.stream, errorText)
				state.status = "Assistant stream failed"
			case:
				state.status = "Assistant response complete"
			}
		}
		if app_clear_assistant_stream_thinking(&state.stream) {
			dirty = true
			state.historyRenderOnly = true
			app_invalidate_assistant_stream_history_entry(state)
		}

		dirty = app_sync_assistant_history_entry(state) || dirty
		state.historyRenderOnly = false
		state.stream.active = false
		hasToolCalls := app_record_stream_tool_turn(state)
		app_clear_assistant_stream_buffers(&state.stream)
		if hasToolCalls {
			dirty = app_process_pending_stream_tool_calls(state) || true
		} else {
			app_clear_assistant_stream_conversation(&state.stream)
			dirty = true
		}
	}

	return dirty
}

app_cancel_assistant_stream :: proc(state: ^App_State) {
	if !state.stream.active {
		state.status = "No assistant stream to cancel"
		return
	}

	if sync.mutex_guard(&state.stream.mutex) {
		state.stream.cancelRequested = true
	}
	state.status = "Canceling assistant stream"
}

app_destroy_assistant_stream :: proc(state: ^App_State) {
	if !state.stream.active {
		app_clear_assistant_stream_buffers(&state.stream)
		app_clear_assistant_stream_tool_calls(&state.stream)
		app_clear_assistant_stream_conversation(&state.stream)
		app_clear_context_window_cache(&state.stream)
		return
	}

	app_cancel_assistant_stream(state)
	if state.stream.worker != nil {
		thread.join(state.stream.worker)
		thread.destroy(state.stream.worker)
		state.stream.worker = nil
	}
	if state.stream.workerData != nil {
		app_destroy_assistant_stream_worker(state.stream.workerData)
		free(state.stream.workerData)
		state.stream.workerData = nil
	}
	state.stream.active = false
	app_clear_assistant_stream_buffers(&state.stream)
	app_clear_assistant_stream_tool_calls(&state.stream)
	app_clear_assistant_stream_conversation(&state.stream)
	app_clear_context_window_cache(&state.stream)
}

app_destroy_tool_execution :: proc(execution: ^Tool_Execution_State) {
	if execution.worker != nil {
		thread.join(execution.worker)
		thread.destroy(execution.worker)
		execution.worker = nil
	}
	if execution.call.id != "" {
		tool_call_destroy(&execution.call, execution.allocator)
	}
	if execution.resultOwned {
		delete(execution.result, execution.allocator)
	}
	execution^ = {}
}

assistant_stream_worker_proc :: proc(workerThread: ^thread.Thread) {
	worker := cast(^Assistant_Stream_Worker)workerThread.data
	assistant_stream_resolve_context_window(worker)
	err := ai.send_chat_completion_stream_with_context(
		worker.client,
		worker.request,
		assistant_stream_delta_callback,
		rawptr(worker.stream),
	)

	if sync.mutex_guard(&worker.stream.mutex) {
		worker.stream.err = err
		worker.stream.finished = true
		if worker.stream.cancelRequested && err == .None {
			worker.stream.canceled = true
		}
	}

}

assistant_stream_delta_callback :: proc(delta: ai.Chat_Stream_Delta, userData: rawptr) -> bool {
	stream := cast(^Assistant_Stream_State)userData
	if sync.mutex_guard(&stream.mutex) {
		if stream.cancelRequested {
			stream.canceled = true
			return false
		}

		if delta.content != "" {
			if delta.isThinking {
				stream.thinking = true
			} else {
				stream.thinking = false
				assistant_stream_append_partial(stream, delta.content)
			}
		}

		if delta.finishReason != "" {
			if stream.finishReason != "" {
				delete(stream.finishReason, stream.bufferAllocator)
			}
			stream.finishReason = strings.clone(delta.finishReason, stream.bufferAllocator)
		}

		if delta.hasToolCall {
			stream.thinking = false
			append(&stream.toolCalls, ai.tool_call_clone(delta.toolCall, stream.bufferAllocator))
		}
		if delta.usage.hasInputTokens {
			stream.usage.inputTokens = delta.usage.inputTokens
			stream.usage.hasInputTokens = true
		}
		if delta.usage.hasOutputTokens {
			stream.usage.outputTokens = delta.usage.outputTokens
			stream.usage.hasOutputTokens = true
		}

		if delta.done && stream.cancelRequested {
			stream.canceled = true
		}
		if delta.done {
			stream.thinking = false
		}
	}
	return true
}

app_build_ai_messages :: proc(
	history: []History_Entry,
	allocator := context.allocator,
) -> [dynamic]ai.Message {
	messages := make([dynamic]ai.Message, 0, len(history), allocator)
	for entry in history {
		if entry.content == "" {
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

app_process_pending_stream_tool_calls :: proc(state: ^App_State) -> bool {
	if state.mode == .Approval || !state.dispatcherReady || state.toolExecution.active {
		return false
	}

	queuedCall: ai.Tool_Call
	hasQueuedCall := false
	if sync.mutex_guard(&state.stream.mutex) {
		if len(state.stream.toolCalls) > 0 {
			queuedCall = ai.tool_call_clone(
				state.stream.toolCalls[0],
				state.stream.bufferAllocator,
			)
			ai.tool_call_destroy(&state.stream.toolCalls[0], state.stream.bufferAllocator)
			ordered_remove(&state.stream.toolCalls, 0)
			hasQueuedCall = true
		}
	}
	if !hasQueuedCall {
		return false
	}
	defer ai.tool_call_destroy(&queuedCall, state.stream.bufferAllocator)

	call, callOK := app_tool_call_from_ai(queuedCall, state.dispatcher.allocator)
	if !callOK {
		toolID := queuedCall.name
		if toolID == "" {
			toolID = "unknown"
		}
		app_append_tool_history(state, toolID, "failed")
		app_append_tool_result(state, queuedCall.id, "Tool call arguments are invalid.", true)
		state.status = "Tool call rejected"
		app_start_tool_continuation_if_ready(state)
		return true
	}
	defer tool_call_destroy(&call, state.dispatcher.allocator)
	historyIndex := app_append_tool_history(state, call.id, "running")

	decision := tool_dispatch_decide(&state.dispatcher, call)
	switch decision {
	case .Approval_Required:
		app_update_tool_history(state, historyIndex, call.id, "awaiting approval")
		if !app_show_approval(state, call) {
			output := "Tool call requires approval."
			app_update_tool_history(state, historyIndex, call.id, "denied")
			app_append_tool_result(state, call.callID, output, true)
			state.status = "Tool call rejected"
			app_start_tool_continuation_if_ready(state)
		} else {
			state.approval.historyIndex = historyIndex
		}
	case .Allowed_Read_Only, .Allowed_Session, .Allowed_Persistent:
		if !app_start_tool_execution(state, call, historyIndex) {
			app_update_tool_history(state, historyIndex, call.id, "failed")
			app_append_tool_result(state, call.callID, "Tool call could not start.", true)
			state.status = "Tool call could not start"
			app_start_tool_continuation_if_ready(state)
		}
	case .Denied:
		app_update_tool_history(state, historyIndex, call.id, "denied")
		app_append_tool_result(state, call.callID, "Permission denied.", true)
		state.status = "Tool call denied"
	}
	if !state.toolExecution.active && state.mode != .Approval {
		app_start_tool_continuation_if_ready(state)
	}
	return true
}

app_start_tool_execution :: proc(state: ^App_State, call: Tool_Call, historyIndex: int) -> bool {
	execution := &state.toolExecution
	if execution.active || call.id == "" {
		return false
	}
	execution.app = state
	execution.call = tool_call_clone(call, execution.allocator)
	execution.historyIndex = historyIndex
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
		delete(output)
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
	toolCallID := execution.call.callID
	toolID := execution.call.id
	isError := app_tool_output_is_error(output)
	if isError {
		app_update_tool_history(state, execution.historyIndex, toolID, "failed")
	} else {
		app_update_tool_history(state, execution.historyIndex, toolID, "completed")
	}
	app_record_tool_execution_result(state, toolCallID, output)
	app_destroy_tool_output_if_owned(output, outputOwned, execution.allocator)
	tool_call_destroy(&execution.call, execution.allocator)
	execution.call = {}
	execution.result = ""
	execution.resultOwned = false
	execution.app = nil
	execution.historyIndex = -1
	execution.active = false
	execution.finished = false
	if isError {
		state.status = "Tool call failed"
	} else {
		state.status = "Tool call completed"
	}
	app_start_tool_continuation_if_ready(state)
	return true
}

app_record_tool_execution_result :: proc(state: ^App_State, toolCallID: string, output: string) {
	isError := app_tool_output_is_error(output)
	app_append_tool_result(state, toolCallID, output, isError)
}

app_tool_output_is_error :: proc(output: string) -> bool {
	return(
		strings.starts_with(output, "Error ") ||
		strings.contains(output, ": Error ") ||
		strings.contains(output, ": Unsupported ") ||
		strings.contains(output, ": Command exited ") ||
		strings.starts_with(output, "File already exists.") ||
		strings.starts_with(output, "Invalid value for overwrite:") ||
		output == "MCP tool dispatch is not implemented." ||
		output == "Permission denied." ||
		output == "Permission approval required." \
	)
}

app_tool_call_from_ai :: proc(
	aiCall: ai.Tool_Call,
	allocator := context.allocator,
) -> (
	Tool_Call,
	bool,
) {
	if aiCall.name == "" || aiCall.arguments == "" {
		return Tool_Call{}, false
	}

	arguments: AI_Tool_Call_Arguments
	decodeErr := json.unmarshal_string(
		aiCall.arguments,
		&arguments,
		allocator = context.temp_allocator,
	)
	if decodeErr != nil {
		return Tool_Call{}, false
	}

	call := Tool_Call {
		callID           = strings.clone(aiCall.id, allocator),
		id               = strings.clone(aiCall.name, allocator),
		filePath         = strings.clone(arguments.file_path, allocator),
		directoryPath    = strings.clone(arguments.directory_path, allocator),
		content          = strings.clone(arguments.content, allocator),
		overwrite        = strings.clone(arguments.overwrite, allocator),
		command          = strings.clone(arguments.command, allocator),
		workingDirectory = strings.clone(arguments.working_directory, allocator),
		timeout          = arguments.timeout,
		mcpServer        = strings.clone(arguments.mcp_server, allocator),
		query            = strings.clone(arguments.query, allocator),
		maxResults       = arguments.max_results,
	}
	if call.id == "search_code" {
		if call.query == "" || call.maxResults < 0 {
			tool_call_destroy(&call, allocator)
			return Tool_Call{}, false
		}
		if call.maxResults == 0 {
			call.maxResults = SEARCH_CODE_DEFAULT_MAX_RESULTS
		} else if call.maxResults > SEARCH_CODE_MAX_RESULTS {
			call.maxResults = SEARCH_CODE_MAX_RESULTS
		}
	}
	return call, true
}

app_execute_tool_call :: proc(state: ^App_State, call: Tool_Call) -> string {
	if call.id != "search_code" {
		return tool_dispatch_execute_approved(&state.dispatcher, call)
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
	defer code_index_search_results_destroy(&results, state.dispatcher.allocator)
	return app_search_code_results_json(&state.codeIndex, results[:], state.dispatcher.allocator)
}

app_search_code_results_json :: proc(
	codeIndex: ^Code_Index,
	results: []Code_Search_Result,
	allocator := context.allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, `{"results":[`)
	for result, index in results {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		location, locationOK := code_index_search_result_location(result)
		strings.write_string(&builder, `{"path":`)
		if locationOK {
			write_json_string(&builder, location.relativePath)
		} else {
			write_json_string(&builder, result.metadata)
		}
		strings.write_string(&builder, `,"start_line":`)
		if locationOK {
			code_index_write_decimal(&builder, location.startLine)
		} else {
			strings.write_byte(&builder, '0')
		}
		strings.write_string(&builder, `,"end_line":`)
		if locationOK {
			code_index_write_decimal(&builder, location.endLine)
		} else {
			strings.write_byte(&builder, '0')
		}
		excerpt := code_index_search_result_excerpt(codeIndex, result, allocator = allocator)
		defer delete(excerpt, allocator)
		strings.write_string(&builder, `,"excerpt":`)
		write_json_string(&builder, excerpt)
		strings.write_byte(&builder, '}')
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder)
}

app_record_stream_tool_turn :: proc(state: ^App_State) -> bool {
	if len(state.stream.toolCalls) == 0 {
		return false
	}

	message := ai.Message {
		role      = .Assistant,
		content   = strings.clone(
			string(state.stream.partialBuffer[:]),
			state.stream.bufferAllocator,
		),
		toolCalls = make(
			[]ai.Tool_Call,
			len(state.stream.toolCalls),
			state.stream.bufferAllocator,
		),
	}
	for call, index in state.stream.toolCalls {
		message.toolCalls[index] = ai.tool_call_clone(call, state.stream.bufferAllocator)
	}
	append(&state.stream.conversation, message)
	return true
}

app_append_tool_result :: proc(
	state: ^App_State,
	toolCallID: string,
	content: string,
	isError: bool,
) {
	if toolCallID == "" || len(state.stream.conversation) == 0 {
		return
	}
	message := ai.Message {
		role        = .Tool,
		toolResults = make([]ai.Tool_Result, 1, state.stream.bufferAllocator),
	}
	message.toolResults[0] = ai.Tool_Result {
		toolCallID = strings.clone(toolCallID, state.stream.bufferAllocator),
		content    = strings.clone(content, state.stream.bufferAllocator),
		isError    = isError,
	}
	append(&state.stream.conversation, message)
}

app_start_tool_continuation_if_ready :: proc(state: ^App_State) {
	if state.stream.active ||
	   state.toolExecution.active ||
	   state.mode != .Chat ||
	   len(state.stream.conversation) == 0 {
		return
	}
	if len(state.stream.toolCalls) > 0 {
		return
	}
	if state.stream.continuationCount >= MAX_TOOL_CONTINUATIONS {
		append_history(state, .Tool, "Tool continuation limit reached.")
		state.status = "Tool continuation limit reached"
		app_clear_assistant_stream_conversation(&state.stream)
		return
	}
	state.stream.continuationCount += 1
	app_start_assistant_stream(state)
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
	}
	return .User, false
}

app_sync_assistant_history_entry :: proc(state: ^App_State) -> bool {
	if state.stream.assistantIndex < 0 || state.stream.assistantIndex >= len(state.history) {
		return false
	}

	partial := ""
	if sync.mutex_guard(&state.stream.mutex) {
		if len(state.stream.partialBuffer) == state.stream.lastSyncedPartialLength {
			return false
		}
		partial = strings.clone(string(state.stream.partialBuffer[:]), context.temp_allocator)
		state.stream.lastSyncedPartialLength = len(state.stream.partialBuffer)
	}

	entry := &state.history[state.stream.assistantIndex]
	if entry.content == partial {
		return false
	}
	if entry.content != "" {
		delete(entry.content)
	}
	entry.content = strings.clone(partial, context.allocator)
	entry.cachedLineWidth = 0
	entry.cachedLineCount = 0
	state.historyScrollOffset = 0
	return true
}

app_append_assistant_stream_error :: proc(state: ^App_State, message: string) {
	append_history(state, .Assistant, message)
	state.status = message
}

app_reset_assistant_stream_state :: proc(stream: ^Assistant_Stream_State) {
	app_clear_assistant_stream_buffers(stream)
	app_clear_assistant_stream_tool_calls(stream)
	stream.assistantIndex = -1
	stream.lastSyncedPartialLength = 0
	stream.err = .None
	stream.finished = false
	stream.cancelRequested = false
	stream.canceled = false
	stream.thinking = false
	stream.spinnerVisible = false
	stream.spinnerFrameIndex = 0
	stream.spinnerLastFrame = {}
	stream.usage = {}
	stream.contextWindowTokens = 0
}

app_clear_assistant_stream_buffers :: proc(stream: ^Assistant_Stream_State) {
	delete(stream.partialBuffer)
	stream.partialBuffer = make([dynamic]byte, 0, 0, stream.bufferAllocator)
	stream.lastSyncedPartialLength = 0
	if stream.finishReason != "" {
		delete(stream.finishReason, stream.bufferAllocator)
		stream.finishReason = ""
	}
}

app_update_assistant_stream_spinner :: proc(stream: ^Assistant_Stream_State) -> Spinner_Update {
	if !sync.mutex_guard(&stream.mutex) {
		return {}
	}

	if !stream.thinking {
		if stream.spinnerVisible {
			stream.spinnerVisible = false
			stream.spinnerFrameIndex = 0
			stream.spinnerLastFrame = {}
			return Spinner_Update{dirty = true, visibilityChanged = true}
		}
		return {}
	}

	if !stream.spinnerVisible {
		stream.spinnerVisible = true
		stream.spinnerFrameIndex = 0
		stream.spinnerLastFrame = time.tick_now()
		return Spinner_Update{dirty = true, visibilityChanged = true}
	}

	if time.tick_since(stream.spinnerLastFrame) >= SPINNER_FRAME_INTERVAL {
		stream.spinnerFrameIndex = (stream.spinnerFrameIndex + 1) % len(SPINNER_FRAMES)
		stream.spinnerLastFrame = time.tick_now()
		return Spinner_Update{dirty = true}
	}
	return {}
}

app_clear_assistant_stream_thinking :: proc(stream: ^Assistant_Stream_State) -> bool {
	if !sync.mutex_guard(&stream.mutex) {
		return false
	}

	wasVisible := stream.spinnerVisible
	stream.thinking = false
	stream.spinnerVisible = false
	stream.spinnerFrameIndex = 0
	stream.spinnerLastFrame = {}
	return wasVisible
}

app_invalidate_assistant_stream_history_entry :: proc(state: ^App_State) {
	index := state.stream.assistantIndex
	if index < 0 || index >= len(state.history) {
		return
	}
	state.history[index].cachedLineWidth = 0
	state.history[index].cachedLineCount = 0
}

app_assistant_stream_spinner_frame :: proc(state: ^App_State) -> string {
	if !sync.mutex_guard(&state.stream.mutex) {
		return ""
	}
	if !state.stream.spinnerVisible {
		return ""
	}
	frames := SPINNER_FRAMES
	return frames[state.stream.spinnerFrameIndex]
}

assistant_stream_append_partial :: proc(stream: ^Assistant_Stream_State, content: string) {
	append(&stream.partialBuffer, ..transmute([]byte)content)
}

app_tool_output_is_owned :: proc(toolID: string) -> bool {
	switch toolID {
	case "read_file", "list_directory", "get_file_info", "list_available_shells", "run_command":
		return true
	case "search_code":
		return true
	}
	return false
}

app_destroy_tool_output_if_owned :: proc(output: string, owned: bool, allocator: mem.Allocator) {
	if owned {
		delete(output, allocator)
	}
}

app_clear_assistant_stream_tool_calls :: proc(stream: ^Assistant_Stream_State) {
	for &call in stream.toolCalls {
		ai.tool_call_destroy(&call, stream.bufferAllocator)
	}
	delete(stream.toolCalls)
	stream.toolCalls = make([dynamic]ai.Tool_Call, 0, 0, stream.bufferAllocator)
}

app_clear_assistant_stream_conversation :: proc(stream: ^Assistant_Stream_State) {
	for &message in stream.conversation {
		ai.message_destroy(&message, stream.bufferAllocator)
	}
	delete(stream.conversation)
	stream.conversation = make([dynamic]ai.Message, 0, 0, stream.bufferAllocator)
	stream.continuationCount = 0
}

assistant_stream_resolve_context_window :: proc(worker: ^Assistant_Stream_Worker) {
	if worker.client.iface.type != .Ollama || worker.request.model == "" {
		return
	}
	stream := worker.stream
	if sync.mutex_guard(&stream.mutex) {
		for entry in stream.contextWindowCache {
			if entry.providerName == worker.client.iface.name &&
			   entry.model == worker.request.model {
				if entry.tokens > 0 {
					stream.contextWindowTokens = entry.tokens
				}
				return
			}
		}
	}

	contextWindowTokens, _ := ai.get_ollama_model_context_window(
		worker.client,
		worker.request.model,
	)
	if sync.mutex_guard(&stream.mutex) {
		entry := Context_Window_Cache_Entry {
			providerName = strings.clone(worker.client.iface.name, stream.bufferAllocator),
			model        = strings.clone(worker.request.model, stream.bufferAllocator),
			tokens       = contextWindowTokens,
		}
		append(&stream.contextWindowCache, entry)
		if contextWindowTokens > 0 {
			stream.contextWindowTokens = contextWindowTokens
		}
	}
}

app_clear_context_window_cache :: proc(stream: ^Assistant_Stream_State) {
	for &entry in stream.contextWindowCache {
		if entry.providerName != "" {
			delete(entry.providerName, stream.bufferAllocator)
		}
		if entry.model != "" {
			delete(entry.model, stream.bufferAllocator)
		}
	}
	delete(stream.contextWindowCache)
	stream.contextWindowCache = make(
		[dynamic]Context_Window_Cache_Entry,
		0,
		0,
		stream.bufferAllocator,
	)
}

app_destroy_assistant_stream_worker :: proc(worker: ^Assistant_Stream_Worker) {
	if worker.request.model != "" {
		delete(worker.request.model)
	}
	delete(worker.toolDefinitions)
}

app_context_usage_status_text :: proc(
	state: ^App_State,
	allocator := context.temp_allocator,
) -> string {
	if state == nil {
		return ""
	}
	usage: ai.Chat_Usage
	contextWindowTokens := 0
	active := false
	if sync.mutex_guard(&state.stream.mutex) {
		usage = state.stream.usage
		contextWindowTokens = state.stream.contextWindowTokens
		active = state.stream.active
	}
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
