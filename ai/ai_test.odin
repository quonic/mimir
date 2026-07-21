package ai

import http "../http"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Test_Stream_State :: struct {
	parts:        [dynamic]string,
	model:        string,
	finishReason: string,
	done:         bool,
	calls:        int,
}

testOpenAIStreamState: Test_Stream_State
testAnthropicStreamState: Test_Stream_State
testOllamaStreamState: Test_Stream_State
testStopStreamState: Test_Stream_State

reset_test_stream_state :: proc(state: ^Test_Stream_State) {
	delete(state.parts)
	state^ = Test_Stream_State{}
}

record_openai_stream_delta :: proc(delta: Chat_Stream_Delta) -> bool {
	record_stream_delta(&testOpenAIStreamState, delta)
	return true
}

record_anthropic_stream_delta :: proc(delta: Chat_Stream_Delta) -> bool {
	record_stream_delta(&testAnthropicStreamState, delta)
	return true
}

record_ollama_stream_delta :: proc(delta: Chat_Stream_Delta) -> bool {
	record_stream_delta(&testOllamaStreamState, delta)
	return true
}

stop_after_first_stream_delta :: proc(delta: Chat_Stream_Delta) -> bool {
	record_stream_delta(&testStopStreamState, delta)
	return false
}

record_context_stream_delta :: proc(delta: Chat_Stream_Delta, userData: rawptr) -> bool {
	state := cast(^Test_Stream_State)userData
	record_stream_delta(state, delta)
	return true
}

record_stream_delta :: proc(state: ^Test_Stream_State, delta: Chat_Stream_Delta) {
	state.calls += 1
	if delta.content != "" {
		append(&state.parts, delta.content)
	}
	if delta.model != "" {
		state.model = delta.model
	}
	if delta.finishReason != "" {
		state.finishReason = delta.finishReason
	}
	if delta.done {
		state.done = true
	}
}

free_model_list :: proc(models: [dynamic]string) {
	for model in models {
		delete(model)
	}
	delete(models)
}

TEST_OLLAMA_SERVER :: "localhost"

@(test)
test_build_openai_chat_request :: proc(t: ^testing.T) {
	request := Chat_Request {
		model       = "test-model",
		temperature = 0.3,
		maxTokens   = 128,
		messages    = []Message {
			{role = .System, content = "You are concise."},
			{role = .User, content = "Hello"},
		},
	}

	wire := build_openai_chat_request(request)
	assert(wire.model == "test-model", "expected model to be propagated to OpenAI payload")
	assert(len(wire.messages) == 2, "expected OpenAI payload to include all messages")
	assert(wire.messages[0].role == "system", "expected first OpenAI role to be system")
	assert(wire.messages[1].content == "Hello", "expected OpenAI message content to be preserved")
	assert(!wire.stream, "expected OpenAI chat payload to disable streaming")

	streamWire := build_openai_chat_stream_request(request)
	assert(streamWire.stream, "expected OpenAI stream payload to enable streaming")
	_ = t
}

@(test)
test_openai_request_and_response_support_tool_calls :: proc(t: ^testing.T) {
	request := Chat_Request {
		model    = "test-model",
		messages = []Message{{role = .User, content = "Inspect the project"}},
		tools    = []Tool_Definition {
			{
				name = "read_file",
				description = "Read a project file",
				parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"}}}`,
			},
		},
	}
	wire := build_openai_chat_request(request)
	assert(len(wire.tools) == 1, "expected OpenAI request tool")
	assert(wire.tools[0].type == "function", "expected OpenAI function tool")
	assert(wire.tools[0].function.name == "read_file", "expected OpenAI tool name")

	payload := `{"model":"gpt-test","choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"read_file","arguments":"{\\"file_path\\":\\"main.odin\\"}"}}]},"finish_reason":"tool_calls"}]}`
	response, err := parse_openai_chat_response(payload, context.allocator)
	defer chat_response_destroy(&response, context.allocator)
	assert(err == .None, "expected OpenAI tool call response")
	assert(len(response.toolCalls) == 1, "expected parsed OpenAI tool call")
	assert(response.toolCalls[0].name == "read_file", "expected parsed OpenAI tool name")
	_ = t
}

@(test)
test_tool_call_clone_and_response_destroy :: proc(t: ^testing.T) {
	call := Tool_Call {
		id        = "call-1",
		name      = "read_file",
		arguments = `{"file_path":"main.odin"}`,
	}
	clone := tool_call_clone(call, context.allocator)
	defer tool_call_destroy(&clone, context.allocator)
	assert(clone.id == "call-1", "expected cloned tool call ID")
	assert(clone.name == "read_file", "expected cloned tool call name")
	assert(clone.arguments == call.arguments, "expected cloned tool call arguments")

	response := Chat_Response {
		content   = strings.clone("", context.allocator),
		model     = strings.clone("test", context.allocator),
		toolCalls = make([dynamic]Tool_Call, 0, 1, context.allocator),
	}
	append(&response.toolCalls, tool_call_clone(call, context.allocator))
	chat_response_destroy(&response, context.allocator)
	assert(len(response.toolCalls) == 0, "expected response destroy to clear tool calls")
	_ = t
}

@(test)
test_build_ollama_chat_request :: proc(t: ^testing.T) {
	request := Chat_Request {
		model       = "llama3.2",
		temperature = 0.4,
		maxTokens   = 96,
		messages    = []Message {
			{role = .System, content = "You are concise."},
			{role = .User, content = "Hello"},
		},
	}

	wire := build_ollama_chat_request(request)
	assert(wire.model == "llama3.2", "expected model to be propagated to Ollama payload")
	assert(len(wire.messages) == 2, "expected Ollama payload to include all messages")
	assert(wire.messages[0].role == "system", "expected first Ollama role to be system")
	assert(wire.messages[1].content == "Hello", "expected Ollama message content to be preserved")
	assert(!wire.stream, "expected native Ollama payload to disable streaming")
	assert(wire.options.temperature == 0.4, "expected temperature to map to Ollama options")
	assert(wire.options.num_predict == 96, "expected max tokens to map to Ollama num_predict")

	streamWire := build_ollama_chat_stream_request(request)
	assert(streamWire.stream, "expected native Ollama stream payload to enable streaming")
	_ = t
}

@(test)
test_build_anthropic_stream_request :: proc(t: ^testing.T) {
	request := Chat_Request {
		model     = "claude-sonnet-4",
		messages  = []Message{{role = .User, content = "Hello"}},
		maxTokens = 128,
	}

	wire := build_anthropic_request(request)
	assert(!wire.stream, "expected Anthropic message payload to disable streaming")

	streamWire := build_anthropic_stream_request(request)
	assert(streamWire.stream, "expected Anthropic stream payload to enable streaming")
	_ = t
}

@(test)
test_parse_openai_chat_response :: proc(t: ^testing.T) {
	payload := `{"model":"llama3.2","choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}`
	response, err := parse_openai_chat_response(payload)
	defer {
		delete(response.content)
		delete(response.model)
		delete(response.finishReason)
	}
	assert(err == .None, "expected valid OpenAI response payload to parse")
	assert(response.content == "hi", "expected parsed OpenAI content to match payload")
	assert(response.model == "llama3.2", "expected parsed OpenAI model to match payload")
	_ = t
}

@(test)
test_parse_ollama_chat_response :: proc(t: ^testing.T) {
	payload := `{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":true,"done_reason":"stop"}`
	response, err := parse_ollama_chat_response(payload)
	defer {
		delete(response.content)
		delete(response.model)
		delete(response.finishReason)
	}
	assert(err == .None, "expected valid Ollama response payload to parse")
	assert(response.content == "hi", "expected parsed Ollama content to match payload")
	assert(response.model == "llama3.2", "expected parsed Ollama model to match payload")
	assert(response.finishReason == "stop", "expected Ollama done reason to be preserved")
	_ = t
}

@(test)
test_parse_anthropic_response :: proc(t: ^testing.T) {
	payload := `{"model":"claude-sonnet-4","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}`
	response, err := parse_anthropic_response(payload)
	defer {
		delete(response.content)
		delete(response.model)
		delete(response.finishReason)
	}
	assert(err == .None, "expected valid Anthropic response payload to parse")
	assert(response.content == "hello", "expected parsed Anthropic content to match payload")
	assert(response.finishReason == "end_turn", "expected Anthropic stop reason to be preserved")
	_ = t
}

@(test)
test_anthropic_request_and_response_support_tool_calls :: proc(t: ^testing.T) {
	request := Chat_Request {
		model    = "claude-test",
		messages = []Message{{role = .User, content = "Inspect the project"}},
		tools    = []Tool_Definition {
			{
				name = "read_file",
				description = "Read a project file",
				parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"}}}`,
			},
		},
	}
	wire := build_anthropic_request(request)
	assert(len(wire.tools) == 1, "expected Anthropic request tool")
	assert(wire.tools[0].name == "read_file", "expected Anthropic tool name")

	payload := `{"model":"claude-test","content":[{"type":"tool_use","id":"tool-1","name":"read_file","input":{"file_path":"main.odin"}}],"stop_reason":"tool_use"}`
	response, err := parse_anthropic_response(payload, context.allocator)
	defer chat_response_destroy(&response, context.allocator)
	assert(err == .None, "expected Anthropic tool call response")
	assert(len(response.toolCalls) == 1, "expected parsed Anthropic tool call")
	assert(response.toolCalls[0].arguments != "", "expected serialized Anthropic arguments")
	_ = t
}

@(test)
test_parse_openai_stream_body :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOpenAIStreamState)
	defer reset_test_stream_state(&testOpenAIStreamState)

	payload :=
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" +
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" +
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
		"data: [DONE]\n\n"
	err := parse_sse_stream_body(payload, record_openai_stream_delta, parse_openai_stream_event)

	assert(err == .None, "expected OpenAI stream body to parse")
	assert(len(testOpenAIStreamState.parts) == 2, "expected OpenAI stream to emit text deltas")
	assert(testOpenAIStreamState.parts[0] == "Hel", "expected first OpenAI delta to match")
	assert(testOpenAIStreamState.parts[1] == "lo", "expected second OpenAI delta to match")
	assert(
		testOpenAIStreamState.model == "gpt-test",
		"expected OpenAI stream model to be preserved",
	)
	assert(testOpenAIStreamState.finishReason == "stop", "expected OpenAI finish reason")
	assert(testOpenAIStreamState.done, "expected OpenAI stream to mark done")
	_ = t
}

@(test)
test_parse_openai_stream_reasoning_delta :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOpenAIStreamState)
	defer reset_test_stream_state(&testOpenAIStreamState)

	payload := "data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"\",\"reasoning\":\"Thinking\"},\"finish_reason\":null}]}\n\n"
	err := parse_sse_stream_body(payload, record_openai_stream_delta, parse_openai_stream_event)

	assert(err == .None, "expected OpenAI reasoning stream body to parse")
	assert(len(testOpenAIStreamState.parts) == 1, "expected OpenAI reasoning delta to be emitted")
	assert(
		testOpenAIStreamState.parts[0] == "Thinking",
		"expected reasoning delta to be surfaced as content",
	)
	_ = t
}

@(test)
test_parse_anthropic_stream_body :: proc(t: ^testing.T) {
	reset_test_stream_state(&testAnthropicStreamState)
	defer reset_test_stream_state(&testAnthropicStreamState)

	payload :=
		"event: message_start\n" +
		"data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-test\"}}\n\n" +
		"event: content_block_delta\n" +
		"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n" +
		"event: message_delta\n" +
		"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n" +
		"event: message_stop\n" +
		"data: {\"type\":\"message_stop\"}\n\n"
	err := parse_sse_stream_body(
		payload,
		record_anthropic_stream_delta,
		parse_anthropic_stream_event,
	)

	assert(err == .None, "expected Anthropic stream body to parse")
	assert(
		len(testAnthropicStreamState.parts) == 1,
		"expected Anthropic stream to emit text delta",
	)
	assert(testAnthropicStreamState.parts[0] == "Hi", "expected Anthropic text delta to match")
	assert(testAnthropicStreamState.model == "claude-test", "expected Anthropic stream model")
	assert(testAnthropicStreamState.finishReason == "end_turn", "expected Anthropic finish reason")
	assert(testAnthropicStreamState.done, "expected Anthropic stream to mark done")
	_ = t
}

@(test)
test_parse_ollama_stream_body :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOllamaStreamState)
	defer reset_test_stream_state(&testOllamaStreamState)

	payload :=
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"o\"},\"done\":false}\n" +
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"k\"},\"done\":false}\n" +
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n"
	err := parse_json_lines_stream_body(
		payload,
		record_ollama_stream_delta,
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected Ollama stream body to parse")
	assert(len(testOllamaStreamState.parts) == 2, "expected Ollama stream to emit text deltas")
	assert(testOllamaStreamState.parts[0] == "o", "expected first Ollama delta to match")
	assert(testOllamaStreamState.parts[1] == "k", "expected second Ollama delta to match")
	assert(testOllamaStreamState.model == "llama3.2", "expected Ollama stream model")
	assert(testOllamaStreamState.finishReason == "stop", "expected Ollama finish reason")
	assert(testOllamaStreamState.done, "expected Ollama stream to mark done")
	_ = t
}

@(test)
test_parse_stream_body_with_context_callback :: proc(t: ^testing.T) {
	state: Test_Stream_State
	defer reset_test_stream_state(&state)

	payload :=
		`{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}` +
		"\n" +
		`{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}` +
		"\n"

	err := parse_json_lines_stream_body_internal(
		payload,
		Chat_Stream_Callback_State {
			callbackWithContext = record_context_stream_delta,
			userData = rawptr(&state),
		},
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected context stream body to parse")
	assert(len(state.parts) == 1, "expected context callback to receive content")
	assert(state.parts[0] == "ok", "expected context callback content to match")
	assert(state.done, "expected context callback to receive done event")
	_ = t
}

@(test)
test_parse_sse_stream_chunks :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOpenAIStreamState)
	defer reset_test_stream_state(&testOpenAIStreamState)

	state: Stream_Parse_State
	defer destroy_stream_parse_state(&state)

	stop, err := parse_sse_stream_chunk(
		&state,
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"He",
		Chat_Stream_Callback_State{callback = record_openai_stream_delta},
		parse_openai_stream_event,
	)
	assert(err == .None, "expected partial SSE chunk to parse without error")
	assert(!stop, "expected partial SSE chunk not to stop")
	assert(len(testOpenAIStreamState.parts) == 0, "expected partial SSE chunk not to emit")

	stop, err = parse_sse_stream_chunk(
		&state,
		"l\"}}]}\n\ndata: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n",
		Chat_Stream_Callback_State{callback = record_openai_stream_delta},
		parse_openai_stream_event,
	)

	assert(err == .None, "expected complete SSE chunks to parse")
	assert(!stop, "expected complete SSE chunks not to stop")
	assert(len(testOpenAIStreamState.parts) == 2, "expected two SSE deltas to emit")
	assert(testOpenAIStreamState.parts[0] == "Hel", "expected split SSE delta to match")
	assert(testOpenAIStreamState.parts[1] == "lo", "expected second SSE delta to match")
	_ = t
}

@(test)
test_parse_json_lines_stream_chunks :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOllamaStreamState)
	defer reset_test_stream_state(&testOllamaStreamState)

	state: Stream_Parse_State
	defer destroy_stream_parse_state(&state)

	stop, err := parse_json_lines_stream_chunk(
		&state,
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"o",
		Chat_Stream_Callback_State{callback = record_ollama_stream_delta},
		parse_ollama_stream_event,
	)
	assert(err == .None, "expected partial JSONL chunk to parse without error")
	assert(!stop, "expected partial JSONL chunk not to stop")
	assert(len(testOllamaStreamState.parts) == 0, "expected partial JSONL chunk not to emit")

	stop, err = parse_json_lines_stream_chunk(
		&state,
		"k\"},\"done\":false}\n{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\"}\n",
		Chat_Stream_Callback_State{callback = record_ollama_stream_delta},
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected complete JSONL chunks to parse")
	assert(!stop, "expected complete JSONL chunks not to stop")
	assert(len(testOllamaStreamState.parts) == 1, "expected one JSONL content delta to emit")
	assert(testOllamaStreamState.parts[0] == "ok", "expected split JSONL delta to match")
	assert(testOllamaStreamState.done, "expected JSONL done event to emit")
	_ = t
}

@(test)
test_stream_chunk_callback_stop :: proc(t: ^testing.T) {
	reset_test_stream_state(&testStopStreamState)
	defer reset_test_stream_state(&testStopStreamState)

	state: Stream_Parse_State
	defer destroy_stream_parse_state(&state)

	stop, err := parse_json_lines_stream_chunk(
		&state,
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"a\"},\"done\":false}\n" +
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"b\"},\"done\":false}\n",
		Chat_Stream_Callback_State{callback = stop_after_first_stream_delta},
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected callback stop to return without error")
	assert(stop, "expected parser to report callback stop")
	assert(testStopStreamState.calls == 1, "expected parser to stop after first callback")
	assert(len(testStopStreamState.parts) == 1, "expected only one stopped delta")
	assert(testStopStreamState.parts[0] == "a", "expected first stopped delta to match")
	_ = t
}

@(test)
test_parse_openai_models_response :: proc(t: ^testing.T) {
	payload := `{"data":[{"id":"qwen3.6"},{"id":"gemma4"}]}`
	models, err := parse_openai_models_response(payload)
	defer free_model_list(models)

	assert(err == .None, "expected valid OpenAI models response payload to parse")
	assert(len(models) == 2, "expected OpenAI models response to return two model IDs")
	assert(models[0] == "qwen3.6", "expected first OpenAI model ID to match payload")
	assert(models[1] == "gemma4", "expected second OpenAI model ID to match payload")
	_ = t
}

@(test)
test_parse_ollama_models_response :: proc(t: ^testing.T) {
	payload := `{"models":[{"name":"qwen3.6"},{"name":"gemma4"}]}`
	models, err := parse_ollama_models_response(payload)
	defer free_model_list(models)

	assert(err == .None, "expected valid Ollama models response payload to parse")
	assert(len(models) == 2, "expected Ollama models response to return two model names")
	assert(models[0] == "qwen3.6", "expected first Ollama model name to match payload")
	assert(models[1] == "gemma4", "expected second Ollama model name to match payload")
	_ = t
}

@(test)
test_parse_anthropic_models_response :: proc(t: ^testing.T) {
	payload := `{"data":[{"id":"claude-sonnet-4"},{"id":"claude-haiku-3.5"}]}`
	models, err := parse_anthropic_models_response(payload)
	defer free_model_list(models)

	assert(err == .None, "expected valid Anthropic models response payload to parse")
	assert(len(models) == 2, "expected Anthropic models response to return two model IDs")
	assert(models[0] == "claude-sonnet-4", "expected first Anthropic model ID to match payload")
	assert(models[1] == "claude-haiku-3.5", "expected second Anthropic model ID to match payload")
	_ = t
}

@(test)
test_probe_ollama_endpoint_rejects_invalid_url :: proc(t: ^testing.T) {
	models, err := probe_ollama_endpoint("localhost:11434", context.temp_allocator)
	defer free_model_list(models)

	assert(err == .Invalid_Request, "expected invalid Ollama endpoint URL to reject")
	assert(len(models) == 0, "expected invalid Ollama endpoint to return no models")
	_ = t
}

@(test)
test_compose_endpoint_target :: proc(t: ^testing.T) {
	withVersion := http.url_parse("http://localhost:11434/v1")
	target1, ok1 := compose_endpoint_target(withVersion, "/chat/completions")
	assert(ok1, "expected compose_endpoint_target to accept endpoint with host")
	assert(
		target1 == "http://localhost:11434/v1/chat/completions",
		"expected endpoint composition to keep version path",
	)

	withTrailingSlash := http.url_parse("http://localhost:11434/v1/")
	target2, ok2 := compose_endpoint_target(withTrailingSlash, "/chat/completions")
	assert(ok2, "expected compose_endpoint_target to support trailing slash")
	assert(
		target2 == "http://localhost:11434/v1/chat/completions",
		"expected endpoint composition to avoid duplicated slash",
	)
	_ = t
}

@(test)
test_ollama_openai_compatible_integration :: proc(t: ^testing.T) {
	enabled := os.get_env("AI_OLLAMA_INTEGRATION", context.temp_allocator) == "1"
	if !enabled {
		_ = t
		return
	}

	model := os.get_env("AI_OLLAMA_MODEL", context.temp_allocator)
	if model == "" {
		_ = t
		return
	}

	endpoint := os.get_env("AI_OLLAMA_ENDPOINT", context.temp_allocator)
	if endpoint == "" {
		endpoint = fmt.aprintf("http://%s:11434/v1", TEST_OLLAMA_SERVER, context.temp_allocator)
	}

	client := Client {
		iface = Interface{name = "ollama", type = .OpenAI, endpoint = http.url_parse(endpoint)},
		apiKey = os.get_env("AI_OLLAMA_API_KEY", context.temp_allocator),
	}

	response, err := send_chat_completion(
		client,
		Chat_Request {
			model = model,
			messages = []Message{{role = .User, content = "Reply with exactly: ok"}},
			temperature = 0,
			maxTokens = 16,
		},
	)
	defer {
		delete(response.content)
		delete(response.model)
		delete(response.finishReason)
	}
	assert(err == .None, "expected Ollama OpenAI-compatible request to succeed")
	assert(len(response.content) > 0, "expected Ollama response content to be non-empty")

	models, modelsErr := list_models(client)
	defer free_model_list(models)
	assert(modelsErr == .None, "expected Ollama OpenAI-compatible model list request to succeed")
	assert(len(models) > 0, "expected Ollama model list to be non-empty")
	_ = t
}

@(test)
test_ollama_native_integration :: proc(t: ^testing.T) {
	enabled := os.get_env("AI_OLLAMA_NATIVE_INTEGRATION", context.temp_allocator) == "1"
	if !enabled {
		_ = t
		return
	}

	model := os.get_env("AI_OLLAMA_MODEL", context.temp_allocator)
	if model == "" {
		_ = t
		return
	}

	endpoint := os.get_env("AI_OLLAMA_ENDPOINT", context.temp_allocator)
	if endpoint == "" {
		endpoint = fmt.aprintf("http://%s:11434", TEST_OLLAMA_SERVER, context.temp_allocator)
	}

	client := Client {
		iface = Interface{name = "ollama", type = .Ollama, endpoint = http.url_parse(endpoint)},
		apiKey = os.get_env("AI_OLLAMA_API_KEY", context.temp_allocator),
	}

	response, err := send_chat_completion(
		client,
		Chat_Request {
			model = model,
			messages = []Message{{role = .User, content = "Reply with exactly: ok"}},
			temperature = 0,
			maxTokens = 16,
		},
	)
	defer {
		delete(response.content)
		delete(response.model)
		delete(response.finishReason)
	}
	assert(err == .None, "expected native Ollama request to succeed")
	assert(len(response.content) > 0, "expected native Ollama response content to be non-empty")

	models, modelsErr := list_models(client)
	defer free_model_list(models)
	assert(modelsErr == .None, "expected native Ollama model list request to succeed")
	assert(len(models) > 0, "expected native Ollama model list to be non-empty")
	_ = t
}
