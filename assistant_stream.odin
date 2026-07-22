package main

import "ai"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

MAX_TOOL_CONTINUATIONS :: 8
MAX_RETAINED_TOOL_OUTPUT_BYTES :: 64 * 1024

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
	toolCalls:               [dynamic]ai.Tool_Call,
	conversation:            [dynamic]ai.Message,
	continuationCount:       int,
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
}

assistant_stream_worker_proc :: proc(workerThread: ^thread.Thread) {
	worker := cast(^Assistant_Stream_Worker)workerThread.data
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
			assistant_stream_append_partial(stream, delta.content)
		}

		if delta.finishReason != "" {
			if stream.finishReason != "" {
				delete(stream.finishReason, stream.bufferAllocator)
			}
			stream.finishReason = strings.clone(delta.finishReason, stream.bufferAllocator)
		}

		if delta.hasToolCall {
			append(&stream.toolCalls, ai.tool_call_clone(delta.toolCall, stream.bufferAllocator))
		}

		if delta.done && stream.cancelRequested {
			stream.canceled = true
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
	if state.mode == .Approval || !state.dispatcherReady {
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
		append_history(state, .Tool, "Tool call arguments are invalid.")
		app_append_tool_result(state, queuedCall.id, "Tool call arguments are invalid.", true)
		state.status = "Tool call rejected"
		app_start_tool_continuation_if_ready(state)
		return true
	}
	defer tool_call_destroy(&call, state.dispatcher.allocator)

	decision := tool_dispatch_decide(&state.dispatcher, call)
	switch decision {
	case .Approval_Required:
		if !app_show_approval(state, call) {
			output := "Tool call requires approval."
			append_history(state, .Tool, output)
			app_append_tool_result(state, call.callID, output, true)
			state.status = "Tool call rejected"
			app_start_tool_continuation_if_ready(state)
		}
	case .Allowed_Read_Only, .Allowed_Session, .Allowed_Persistent:
		output := tool_dispatch_execute(&state.dispatcher, call)
		outputOwned := app_tool_output_is_owned(call.id)
		if len(output) > MAX_RETAINED_TOOL_OUTPUT_BYTES {
			truncatedOutput := strings.concatenate(
				{
					output[:MAX_RETAINED_TOOL_OUTPUT_BYTES],
					"\n\n[Tool output truncated after 64 KiB.]",
				},
				state.dispatcher.allocator,
			)
			if outputOwned {
				delete(output, state.dispatcher.allocator)
			}
			output = truncatedOutput
			outputOwned = true
		}
		defer app_destroy_tool_output_if_owned(output, outputOwned, state.dispatcher.allocator)
		app_record_tool_execution_result(state, call.callID, output)
		state.status = "Tool call completed"
	case .Denied:
		append_history(state, .Tool, "Permission denied.")
		app_append_tool_result(state, call.callID, "Permission denied.", true)
		state.status = "Tool call denied"
	}
	app_start_tool_continuation_if_ready(state)
	return true
}

app_record_tool_execution_result :: proc(state: ^App_State, toolCallID: string, output: string) {
	isError := app_tool_output_is_error(output)
	if isError {
		append_history(state, .Tool, output)
	}
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
	}
	return call, true
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
	if state.stream.active || state.mode != .Chat || len(state.stream.conversation) == 0 {
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

assistant_stream_append_partial :: proc(stream: ^Assistant_Stream_State, content: string) {
	append(&stream.partialBuffer, ..transmute([]byte)content)
}

app_tool_output_is_owned :: proc(toolID: string) -> bool {
	switch toolID {
	case "read_file", "list_directory", "get_file_info", "list_available_shells", "run_command":
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

app_destroy_assistant_stream_worker :: proc(worker: ^Assistant_Stream_Worker) {
	if worker.request.model != "" {
		delete(worker.request.model)
	}
	delete(worker.toolDefinitions)
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
