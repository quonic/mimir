package main

import "ai"
import "core:strings"
import "core:sync"
import "core:thread"

Assistant_Stream_State :: struct {
	mutex:           sync.Mutex,
	worker:          ^thread.Thread,
	workerData:      ^Assistant_Stream_Worker,
	assistantIndex:  int,
	partial:         string,
	finishReason:    string,
	err:             ai.AI_Error,
	active:          bool,
	finished:        bool,
	cancelRequested: bool,
	canceled:        bool,
}

Assistant_Stream_Worker :: struct {
	stream:   ^Assistant_Stream_State,
	client:   ai.Client,
	request:  ai.Chat_Request,
	messages: [dynamic]ai.Message,
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

	messages := app_build_ai_messages(state.history[:], context.allocator)
	if len(messages) == 0 {
		delete(messages)
		app_append_assistant_stream_error(state, "No chat messages to send")
		return
	}

	append_history(state, .Assistant, "")
	assistantIndex := len(state.history) - 1

	workerData := new(Assistant_Stream_Worker)
	workerData.stream = &state.stream
	workerData.client = client
	workerData.messages = messages
	workerData.request = ai.Chat_Request {
		model       = strings.clone(model, context.allocator),
		messages    = workerData.messages[:],
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
		return false
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
			free(state.stream.workerData)
			state.stream.workerData = nil
		}

		if sync.mutex_guard(&state.stream.mutex) {
			switch {
			case state.stream.canceled:
				state.status = "Assistant stream canceled"
			case state.stream.err != .None:
				errorText := assistant_stream_error_text(state.stream.err)
				if state.stream.partial == "" {
					state.stream.partial = strings.clone(errorText, context.allocator)
				} else {
					combined := strings.concatenate(
						{state.stream.partial, "\n\n", errorText},
						context.allocator,
					)
					delete(state.stream.partial)
					state.stream.partial = combined
				}
				state.status = "Assistant stream failed"
			case:
				state.status = "Assistant response complete"
			}
		}

		dirty = app_sync_assistant_history_entry(state) || dirty
		state.historyRenderOnly = false
		state.stream.active = false
		app_clear_assistant_stream_buffers(&state.stream)
		dirty = true
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
		return
	}

	app_cancel_assistant_stream(state)
	if state.stream.worker != nil {
		thread.join(state.stream.worker)
		thread.destroy(state.stream.worker)
		state.stream.worker = nil
	}
	if state.stream.workerData != nil {
		free(state.stream.workerData)
		state.stream.workerData = nil
	}
	state.stream.active = false
	app_clear_assistant_stream_buffers(&state.stream)
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

	app_destroy_assistant_stream_worker(worker)
}

assistant_stream_delta_callback :: proc(delta: ai.Chat_Stream_Delta, userData: rawptr) -> bool {
	stream := cast(^Assistant_Stream_State)userData
	if sync.mutex_guard(&stream.mutex) {
		if stream.cancelRequested {
			stream.canceled = true
			return false
		}

		if delta.content != "" {
			combined := strings.concatenate({stream.partial, delta.content}, context.allocator)
			if stream.partial != "" {
				delete(stream.partial)
			}
			stream.partial = combined
		}

		if delta.finishReason != "" {
			if stream.finishReason != "" {
				delete(stream.finishReason)
			}
			stream.finishReason = strings.clone(delta.finishReason, context.allocator)
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
		partial = strings.clone(state.stream.partial, context.temp_allocator)
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
	stream.assistantIndex = -1
	stream.err = .None
	stream.finished = false
	stream.cancelRequested = false
	stream.canceled = false
}

app_clear_assistant_stream_buffers :: proc(stream: ^Assistant_Stream_State) {
	if stream.partial != "" {
		delete(stream.partial)
		stream.partial = ""
	}
	if stream.finishReason != "" {
		delete(stream.finishReason)
		stream.finishReason = ""
	}
}

app_destroy_assistant_stream_worker :: proc(worker: ^Assistant_Stream_Worker) {
	for message in worker.messages {
		delete(message.content)
	}
	delete(worker.messages)
	if worker.request.model != "" {
		delete(worker.request.model)
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
