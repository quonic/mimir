#+vet explicit-allocators
package ai

import http "../http"
import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Test_Stream_State :: struct {
	parts:        [dynamic]string,
	partThinking: [dynamic]bool,
	toolCalls:    [dynamic]Tool_Call,
	model:        string,
	finishReason: string,
	done:         bool,
	calls:        int,
	usage:        Chat_Usage,
}

testOllamaStreamState: Test_Stream_State
testStopStreamState: Test_Stream_State

reset_test_stream_state :: proc(state: ^Test_Stream_State) {
	delete(state.parts)
	delete(state.partThinking)
	for &call in state.toolCalls {
		tool_call_destroy(&call, context.allocator)
	}
	delete(state.toolCalls)
	state^ = Test_Stream_State{}
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
		append(&state.partThinking, delta.isThinking)
	}
	if delta.hasToolCall {
		append(&state.toolCalls, tool_call_clone(delta.toolCall, context.allocator))
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
	if delta.usage.hasInputTokens {
		state.usage.inputTokens = delta.usage.inputTokens
		state.usage.hasInputTokens = true
	}
	if delta.usage.hasOutputTokens {
		state.usage.outputTokens = delta.usage.outputTokens
		state.usage.hasOutputTokens = true
	}
}

free_model_list :: proc(models: ^[dynamic]string, allocator := context.allocator) {
	// for &model in models {
	// 	delete(model, context.allocator)
	// }
	free(models, allocator = allocator)
}

TEST_OLLAMA_SERVER :: "localhost"

@(test)
test_build_ollama_embedding_request :: proc(t: ^testing.T) {
	options, parseErr := json.parse_string(`{"num_ctx":2048}`, allocator = context.temp_allocator)
	assert(parseErr == .None, "expected Ollama options JSON to parse")
	wire := build_ollama_embedding_request(
		Embedding_Batch_Request {
			model = "nomic-embed-text",
			inputs = []string{"first"},
			options = Embedding_Options {
				dimensions = 256,
				hasDimensions = true,
				ollamaTruncate = false,
				hasOllamaTruncate = true,
				ollamaKeepAlive = "5m",
				hasOllamaKeepAlive = true,
				ollamaOptions = options,
				hasOllamaOptions = true,
			},
		},
		allocator = context.temp_allocator,
	)
	payload, marshalErr := json.unparse(wire, allocator = context.temp_allocator)
	assert(marshalErr == nil, "expected Ollama embedding request to serialize")
	assert(strings.contains(payload, `"input":"first"`), "expected single string input")
	assert(strings.contains(payload, `"dimensions":256`), "expected requested dimensions")
	assert(strings.contains(payload, `"truncate":false`), "expected explicit truncate value")
	assert(strings.contains(payload, `"keep_alive":"5m"`), "expected keep alive value")
	assert(strings.contains(payload, `"options"`), "expected Ollama options")
	assert(strings.contains(payload, `"num_ctx"`), "expected Ollama options value")

	defaultWire := build_ollama_embedding_request(
		Embedding_Batch_Request{model = "nomic-embed-text", inputs = []string{"first", "second"}},
		allocator = context.temp_allocator,
	)
	defaultPayload, defaultMarshalErr := json.unparse(
		defaultWire,
		allocator = context.temp_allocator,
	)
	assert(defaultMarshalErr == nil, "expected default Ollama request to serialize")
	assert(strings.contains(defaultPayload, `"input":["first","second"]`), "expected batch input")
	assert(
		!strings.contains(defaultPayload, `"truncate"`),
		"expected unset truncate to be omitted",
	)
	assert(
		!strings.contains(defaultPayload, `"keep_alive"`),
		"expected unset keep alive to be omitted",
	)
	assert(
		!strings.contains(defaultPayload, `"dimensions"`),
		"expected unset dimensions to be omitted",
	)
	_ = t
}

@(test)
test_parse_ollama_embedding_response_and_cleanup :: proc(t: ^testing.T) {
	payload := `{"model":"nomic-embed-text","embeddings":[[0.1,0.2],[0.3,0.4]],"prompt_eval_count":5,"total_duration":12,"load_duration":3}`
	response, err := parse_ollama_embedding_response(payload, 2, context.allocator)
	assert(err == .None, "expected Ollama embedding response to parse")
	assert(response.inputTokenCount == 5, "expected Ollama token count")
	assert(response.totalDuration == 12, "expected Ollama total duration")
	assert(response.loadDuration == 3, "expected Ollama load duration")
	assert(response.embeddings[1][1] == 0.4, "expected Ollama vector value")
	embedding_batch_response_destroy(&response, context.allocator)
	assert(len(response.embeddings) == 0, "expected embedding cleanup to clear vectors")
	assert(response.model == "", "expected embedding cleanup to clear model")
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

	wire := build_ollama_chat_request(request, allocator = context.temp_allocator)
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
test_openai_request_and_response_support_tool_calls :: proc(t: ^testing.T) {
	request := Chat_Request {
		model       = "gpt-test",
		temperature = 0.4,
		maxTokens   = 96,
		messages    = []Message {
			{
				role = .Assistant,
				toolCalls = []Tool_Call {
					{id = "call_1", name = "read_file", arguments = `{"path":"main.odin"}`},
				},
			},
			{
				role = .Tool,
				toolResults = []Tool_Result{{toolCallID = "call_1", content = "package main"}},
			},
		},
		tools       = []Tool_Definition {
			{
				name = "read_file",
				description = "Read a project file",
				parametersJSON = `{"type":"object"}`,
			},
		},
	}
	wire := build_openai_chat_request(request, allocator = context.temp_allocator)
	payloadBytes, marshalErr := json.marshal(wire, allocator = context.temp_allocator)
	payload := string(payloadBytes)
	assert(marshalErr == nil, "expected OpenAI request to serialize")
	assert(strings.contains(payload, `"temperature":0.4`), "expected OpenAI temperature")
	assert(strings.contains(payload, `"max_tokens":96`), "expected OpenAI max tokens")
	assert(strings.contains(payload, `"tool_call_id":"call_1"`), "expected tool call ID")
	assert(!strings.contains(payload, `"tool_calls":[]`), "expected empty tool calls omitted")

	response, err := parse_openai_chat_response(
		`{"model":"gpt-test","choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":\\"main.odin\\"}"}}]},"finish_reason":"tool_calls"}]}`,
		context.allocator,
	)
	defer chat_response_destroy(&response, context.allocator)
	assert(err == .None, "expected OpenAI tool call response")
	assert(len(response.toolCalls) == 1, "expected one parsed OpenAI tool call")
	assert(response.toolCalls[0].id == "call_1", "expected OpenAI tool call ID")
	assert(response.toolCalls[0].arguments == `{"path":"main.odin"}`, "expected arguments")
	_ = t
}

@(test)
test_parse_openai_embedding_and_models_response :: proc(t: ^testing.T) {
	embeddings, embeddingErr := parse_openai_embedding_response(
		`{"model":"text-embedding","data":[{"embedding":[0.1,0.2]}],"usage":{"prompt_tokens":3}}`,
		1,
		context.allocator,
	)
	defer embedding_batch_response_destroy(&embeddings, context.allocator)
	assert(embeddingErr == .None, "expected OpenAI embedding response")
	assert(embeddings.inputTokenCount == 3, "expected OpenAI embedding usage")
	assert(embeddings.embeddings[0][1] == 0.2, "expected OpenAI embedding vector")

	models, modelErr := parse_openai_models_response(
		`{"data":[{"id":"gpt-test"}]}`,
		context.allocator,
	)
	defer models_destroy(&models, context.allocator)
	assert(modelErr == .None, "expected OpenAI models response")
	assert(len(models) == 1, "expected one OpenAI model")
	assert(model_supports_chat(models[0]), "expected OpenAI model chat capability")
	assert(!model_supports_embeddings(models[0]), "expected embedding capability not inferred")
	_ = t
}

@(test)
test_parse_openai_models_response_infers_embedding_by_name :: proc(t: ^testing.T) {
	models, modelErr := parse_openai_models_response(
		`{"data":[{"id":"gpt-test"},{"id":"nomic-embed-text-v2-moe"},{"id":"qwen3-embedding"},{"id":"embeddinggemma"},{"id":"text-embedding-3-small"},{"id":"text-embedding-3-large"}]}`,
		context.allocator,
	)
	defer models_destroy(&models, context.allocator)
	assert(modelErr == .None, "expected OpenAI models response with embedding models to parse")
	assert(len(models) == 6, "expected six OpenAI models")
	assert(model_supports_chat(models[0]), "expected gpt-test to support chat")
	assert(!model_supports_embeddings(models[0]), "expected gpt-test to not support embeddings")
	for index in 1 ..< len(models) {
		assert(
			model_supports_embeddings(models[index]),
			"expected embedding-named model to support embeddings",
		)
		assert(
			!model_supports_chat(models[index]),
			"expected embedding-named model to not support chat",
		)
	}
	_ = t
}

@(test)
test_openai_endpoint_target_and_sse_stream :: proc(t: ^testing.T) {
	root := http.url_parse("https://example.test")
	rootTarget, rootOK := openai_endpoint_target(root, OPENAI_CHAT_PATH)
	assert(rootOK, "expected OpenAI root endpoint")
	assert(
		rootTarget == "https://example.test/v1/chat/completions",
		"expected versioned root target",
	)
	apiBase := http.url_parse("https://example.test/v1/")
	baseTarget, baseOK := openai_endpoint_target(apiBase, OPENAI_CHAT_PATH)
	assert(baseOK, "expected versioned OpenAI endpoint")
	assert(
		baseTarget == "https://example.test/v1/chat/completions",
		"expected no duplicated version",
	)

	state: Test_Stream_State
	defer reset_test_stream_state(&state)
	err := parse_sse_stream_body_internal(
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" +
		"data: {\"model\":\"gpt-test\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}\n\n" +
		"data: [DONE]\n\n",
		Chat_Stream_Callback_State {
			callbackWithContext = record_context_stream_delta,
			userData = rawptr(&state),
		},
		parse_openai_stream_event,
	)
	assert(err == .None, "expected OpenAI SSE body to parse")
	assert(len(state.parts) == 1 && state.parts[0] == "ok", "expected OpenAI content delta")
	assert(state.done, "expected OpenAI final event")
	assert(state.usage.inputTokens == 2, "expected OpenAI prompt token usage")
	_ = t
}

@(test)
test_openai_stream_buffers_fragmented_tool_calls :: proc(t: ^testing.T) {
	state: Test_Stream_State
	defer reset_test_stream_state(&state)
	toolState: OpenAI_Stream_Tool_State
	defer destroy_openai_stream_tool_state(&toolState)
	err := parse_sse_stream_body_internal(
		"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"file\",\"arguments\":\"\\\"main.odin\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
		Chat_Stream_Callback_State {
			callbackWithContext = record_context_stream_delta,
			userData = rawptr(&state),
			parserData = rawptr(&toolState),
		},
		parse_openai_stream_event,
	)
	assert(err == .None, "expected fragmented OpenAI tool stream")
	assert(len(state.toolCalls) == 1, "expected one completed OpenAI tool call")
	assert(state.toolCalls[0].id == "call_1", "expected fragmented tool ID")
	assert(state.toolCalls[0].name == "read_file", "expected fragmented tool name")
	assert(state.toolCalls[0].arguments == `{"path":"main.odin"}`, "expected fragmented arguments")
	assert(state.done, "expected tool-call completion event")
	_ = t
}

@(test)
test_openai_stream_uses_tool_call_indexes :: proc(t: ^testing.T) {
	state: Test_Stream_State
	defer reset_test_stream_state(&state)
	toolState: OpenAI_Stream_Tool_State
	defer destroy_openai_stream_tool_state(&toolState)
	err := parse_sse_stream_body_internal(
		"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"second\",\"arguments\":\"{}\"}},{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"first\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
		Chat_Stream_Callback_State {
			callbackWithContext = record_context_stream_delta,
			userData = rawptr(&state),
			parserData = rawptr(&toolState),
		},
		parse_openai_stream_event,
	)
	assert(err == .None, "expected indexed OpenAI tool stream")
	assert(len(state.toolCalls) == 2, "expected two completed indexed tool calls")
	assert(state.toolCalls[0].id == "call_1", "expected first indexed tool call")
	assert(state.toolCalls[1].id == "call_2", "expected second indexed tool call")
	_ = t
}

@(test)
test_openai_endpoint_transport :: proc(t: ^testing.T) {
	endpoint := os.get_env("MIMIR_OPENAI_PROBE_ENDPOINT", context.temp_allocator)
	if endpoint == "" {
		_ = t
		return
	}
	apiKey := os.get_env("MIMIR_OPENAI_PROBE_KEY", context.temp_allocator)
	models, err := probe_openai_endpoint_with_api_key(endpoint, apiKey, context.allocator)
	defer models_destroy(&models, context.allocator)
	if apiKey == "" {
		assert(err != .Network_Error, "expected OpenAI endpoint to return an HTTP response")
	} else {
		assert(err == .None, "expected authenticated OpenAI model discovery to succeed")
		assert(len(models) > 0, "expected at least one OpenAI model")
	}
	_ = t
}

@(test)
test_ollama_request_and_response_support_tool_calls :: proc(t: ^testing.T) {
	request := Chat_Request {
		model    = "qwen3",
		messages = []Message{{role = .User, content = "Inspect the project"}},
		tools    = []Tool_Definition {
			{
				name = "read_file",
				description = "Read a project file",
				parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"}}}`,
			},
		},
	}
	wire := build_ollama_chat_request(request, allocator = context.temp_allocator)
	assert(len(wire.tools) == 1, "expected Ollama request tool")
	assert(wire.tools[0].type == "function", "expected Ollama function tool")
	assert(wire.tools[0].function.name == "read_file", "expected Ollama tool name")

	payload := `{"model":"qwen3","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"read_file","arguments":{"file_path":"main.odin"}}}]},"done":true,"done_reason":"stop"}`
	response, err := parse_ollama_chat_response(payload, context.allocator)
	defer chat_response_destroy(&response, context.allocator)
	assert(err == .None, "expected Ollama tool call response")
	assert(len(response.toolCalls) == 1, "expected parsed Ollama tool call")
	assert(response.toolCalls[0].id == "ollama-0", "expected synthetic Ollama call ID")
	assert(response.toolCalls[0].name == "read_file", "expected parsed Ollama tool name")
	_ = t
}

@(test)
test_ollama_request_serializes_tool_call_history :: proc(t: ^testing.T) {
	request := Chat_Request {
		model    = "qwen3",
		messages = []Message {
			{
				role = .Assistant,
				toolCalls = []Tool_Call {
					{id = "ollama-0", name = "read_file", arguments = `{"file_path":"main.odin"}`},
				},
			},
			{
				role = .Tool,
				toolResults = []Tool_Result{{toolCallID = "ollama-0", content = "package main"}},
			},
		},
	}
	wire := build_ollama_chat_request(request, allocator = context.temp_allocator)
	assert(len(wire.messages) == 2, "expected assistant call and tool result messages")
	assert(len(wire.messages[0].tool_calls) == 1, "expected Ollama tool-call history")
	assert(
		wire.messages[0].tool_calls[0].function.name == "read_file",
		"expected Ollama tool-call name",
	)
	assert(wire.messages[1].role == "tool", "expected Ollama tool-result role")
	assert(wire.messages[1].content == "package main", "expected Ollama tool result")
	_ = t
}

@(test)
test_parse_ollama_chat_response :: proc(t: ^testing.T) {
	payload := `{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":true,"done_reason":"stop"}`
	response, err := parse_ollama_chat_response(payload, allocator = context.temp_allocator)
	defer {
		delete(response.content, allocator = context.temp_allocator)
		delete(response.model, allocator = context.temp_allocator)
		delete(response.finishReason, allocator = context.temp_allocator)
	}
	assert(err == .None, "expected valid Ollama response payload to parse")
	assert(response.content == "hi", "expected parsed Ollama content to match payload")
	assert(response.model == "llama3.2", "expected parsed Ollama model to match payload")
	assert(response.finishReason == "stop", "expected Ollama done reason to be preserved")
	_ = t
}

@(test)
test_parse_ollama_stream_body :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOllamaStreamState)
	defer reset_test_stream_state(&testOllamaStreamState)

	payload :=
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"o\"},\"done\":false}\n" +
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"k\"},\"done\":false}\n" +
		"{\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":10,\"eval_count\":2}\n"
	err := parse_json_lines_stream_body(
		payload,
		record_ollama_stream_delta,
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected Ollama stream body to parse")
	assert(len(testOllamaStreamState.parts) == 2, "expected Ollama stream to emit text deltas")
	assert(testOllamaStreamState.parts[0] == "o", "expected first Ollama delta to match")
	assert(testOllamaStreamState.parts[1] == "k", "expected second Ollama delta to match")
	assert(
		!testOllamaStreamState.partThinking[0] && !testOllamaStreamState.partThinking[1],
		"expected Ollama content deltas to not be marked as thinking",
	)
	assert(testOllamaStreamState.model == "llama3.2", "expected Ollama stream model")
	assert(testOllamaStreamState.finishReason == "stop", "expected Ollama finish reason")
	assert(testOllamaStreamState.done, "expected Ollama stream to mark done")
	assert(testOllamaStreamState.usage.inputTokens == 10, "expected Ollama prompt tokens")
	assert(testOllamaStreamState.usage.outputTokens == 2, "expected Ollama output tokens")
	_ = t
}

@(test)
test_parse_ollama_stream_thinking_delta :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOllamaStreamState)
	defer reset_test_stream_state(&testOllamaStreamState)

	payload :=
		`{"model":"qwen3","message":{"role":"assistant","content":"","thinking":"Thinking"},"done":false}` +
		"\n"
	err := parse_json_lines_stream_body(
		payload,
		record_ollama_stream_delta,
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected Ollama thinking stream body to parse")
	assert(len(testOllamaStreamState.parts) == 1, "expected one Ollama thinking delta")
	assert(testOllamaStreamState.parts[0] == "Thinking", "expected Ollama thinking text")
	assert(
		testOllamaStreamState.partThinking[0],
		"expected Ollama thinking delta to be marked as thinking",
	)
	_ = t
}

@(test)
test_parse_ollama_stream_tool_calls :: proc(t: ^testing.T) {
	reset_test_stream_state(&testOllamaStreamState)
	defer reset_test_stream_state(&testOllamaStreamState)

	toolState: Ollama_Stream_Tool_State
	payload :=
		`{"model":"qwen3","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"read_file","arguments":{"file_path":"main.odin"}}}]},"done":true,"done_reason":"stop"}` +
		"\n"
	err := parse_json_lines_stream_body_internal(
		payload,
		Chat_Stream_Callback_State {
			callback = record_ollama_stream_delta,
			parserData = rawptr(&toolState),
		},
		parse_ollama_stream_event,
	)

	assert(err == .None, "expected Ollama tool-call stream to parse")
	assert(len(testOllamaStreamState.toolCalls) == 1, "expected one streamed tool call")
	assert(testOllamaStreamState.toolCalls[0].id == "ollama-0", "expected synthetic ID")
	assert(testOllamaStreamState.toolCalls[0].name == "read_file", "expected tool name")
	assert(testOllamaStreamState.done, "expected Ollama tool stream to finish")
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
test_parse_ollama_models_response :: proc(t: ^testing.T) {
	payload := `{"models":[{"name":"completion-only","capabilities":["completion"]},{"name":"chat","capabilities":["completion","tools"]},{"name":"embedding","capabilities":["embedding"]},{"name":"all","capabilities":["completion","tools","embedding"]},{"name":"unknown"}]}`
	models, err := parse_ollama_models_response(payload, allocator = context.temp_allocator)
	defer models_destroy(&models, allocator = context.temp_allocator)

	assert(err == .None, "expected valid Ollama models response payload to parse")
	assert(len(models) == 5, "expected Ollama models response to return all models")
	assert(models[0].name == "completion-only", "expected first Ollama model name to match")
	assert(!model_supports_chat(models[0]), "expected completion-only model to reject chat")
	assert(model_supports_chat(models[1]), "expected completion and tools model to support chat")
	assert(model_supports_embeddings(models[2]), "expected embedding model to support embeddings")
	assert(model_supports_chat(models[3]), "expected all-capability model to support chat")
	assert(
		model_supports_embeddings(models[3]),
		"expected all-capability model to support embeddings",
	)
	assert(!model_supports_chat(models[4]), "expected missing capabilities to reject chat")
	assert(
		!model_supports_embeddings(models[4]),
		"expected missing capabilities to reject embeddings",
	)
	_ = t
}

@(test)
test_parse_ollama_model_context_window :: proc(t: ^testing.T) {
	payload := `{"model_info":{"qwen35moe.context_length":262144,"general.parameter_count":35500000000}}`
	contextWindow, err := parse_ollama_model_context_window(payload)

	assert(err == .None, "expected valid Ollama model info response")
	assert(contextWindow == 262144, "expected context length from prefixed model info key")
	_ = t
}

@(test)
test_parse_ollama_model_context_window_missing_or_invalid :: proc(t: ^testing.T) {
	missingContext, missingErr := parse_ollama_model_context_window(`{"model_info":{}}`)
	assert(missingErr == .None, "expected missing context length to remain nonfatal")
	assert(missingContext == 0, "expected unknown context length when metadata is missing")

	invalidContext, invalidErr := parse_ollama_model_context_window(
		`{"model_info":{"gemma4.context_length":0}}`,
	)
	assert(invalidErr == .None, "expected invalid optional context metadata to remain nonfatal")
	assert(invalidContext == 0, "expected nonpositive context length to be unknown")
	_ = t
}

@(test)
test_probe_ollama_endpoint_rejects_invalid_url :: proc(t: ^testing.T) {
	models, err := probe_ollama_endpoint("localhost:11434", context.temp_allocator)
	defer models_destroy(&models, allocator = context.temp_allocator)

	assert(err == .Invalid_Request, "expected invalid Ollama endpoint URL to reject")
	assert(len(models) == 0, "expected invalid Ollama endpoint to return no models")
	_ = t
}

@(test)
test_new_client_with_endpoint_validates_endpoint :: proc(t: ^testing.T) {
	client, err := new_client_with_endpoint(.Ollama, "http://localhost:11434", "key")
	assert(err == .None, "expected configured endpoint client")
	assert(client.iface.type == .Ollama, "expected configured client type")
	assert(client.iface.endpoint.host == "localhost:11434", "expected configured client endpoint")
	assert(client.apiKey == "key", "expected configured client API key")

	_, invalidErr := new_client_with_endpoint(.Ollama, "localhost:11434", "")
	assert(invalidErr == .Invalid_Request, "expected invalid configured endpoint rejection")
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
		endpoint = fmt.aprintf(
			"http://%s:11434",
			TEST_OLLAMA_SERVER,
			allocator = context.temp_allocator,
		)
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
		delete(response.content, allocator = context.temp_allocator)
		delete(response.model, allocator = context.temp_allocator)
		delete(response.finishReason, allocator = context.temp_allocator)
	}
	assert(err == .None, "expected native Ollama request to succeed")
	assert(len(response.content) > 0, "expected native Ollama response content to be non-empty")

	models, modelsErr := list_models(client, allocator = context.temp_allocator)
	defer free_model_list(&models, allocator = context.temp_allocator)
	assert(modelsErr == .None, "expected native Ollama model list request to succeed")
	assert(len(models) > 0, "expected native Ollama model list to be non-empty")
	_ = t
}

@(test)
test_ollama_native_embedding_integration :: proc(t: ^testing.T) {
	enabled := os.get_env("AI_OLLAMA_NATIVE_INTEGRATION", context.temp_allocator) == "1"
	if !enabled {
		_ = t
		return
	}

	model := os.get_env("AI_OLLAMA_EMBEDDING_MODEL", context.temp_allocator)
	if model == "" {
		_ = t
		return
	}

	endpoint := os.get_env("AI_OLLAMA_ENDPOINT", context.temp_allocator)
	if endpoint == "" {
		endpoint = fmt.aprintf(
			"http://%s:11434",
			TEST_OLLAMA_SERVER,
			allocator = context.temp_allocator,
		)
	}
	client := Client {
		iface = Interface{name = "ollama", type = .Ollama, endpoint = http.url_parse(endpoint)},
		apiKey = os.get_env("AI_OLLAMA_API_KEY", context.temp_allocator),
	}

	response, err := send_embedding(
		client,
		Embedding_Request{model = model, input = "hello"},
		allocator = context.temp_allocator,
	)
	defer embedding_response_destroy(&response, allocator = context.temp_allocator)
	assert(err == .None, "expected native Ollama embedding request to succeed")
	assert(len(response.embedding) > 0, "expected native embedding vector")

	batch, batchErr := send_embeddings(
		client,
		Embedding_Batch_Request{model = model, inputs = []string{"hello", "goodbye"}},
		allocator = context.temp_allocator,
	)
	defer embedding_batch_response_destroy(&batch, allocator = context.temp_allocator)
	assert(batchErr == .None, "expected native Ollama embedding batch to succeed")
	assert(len(batch.embeddings) == 2, "expected two native embedding vectors")
	assert(len(batch.embeddings[0]) > 0, "expected first native embedding vector")
	_ = t
}
