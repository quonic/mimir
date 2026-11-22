package acp

import "../session"
import "../settings"
import "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Tests of the ACP front end. Each test drives a Connection with JSON-RPC lines and reads its
// outbox. The sessions use a session.Fake_Provider, so whole turns run without a model.

TEST_TIMEOUT :: 10 * time.Second
PWD_ARGUMENTS :: `{"command":"pwd"}`

// Numbers the fake providers, so parallel tests register different AI interface names.
testProviderCounter: int

Test_ACP :: struct {
	config:       settings.Mimir_Config,
	provider:     session.Fake_Provider,
	conn:         Connection,
	configHome:   string,
	// Temporary directories that the test removes.
	directories:  [dynamic]string,
	// Every outbound line so far, owned by the test.
	lines:        [dynamic]string,
	nextClientID: int,
}

test_discard_log :: proc(data: rawptr, level: Log_Level, text: string) {}

// Starts a fake provider and a connection whose config uses it. The safety model is missing, so
// the safety classifier is unavailable unless a test selects the fake provider for it.
test_acp_init :: proc(test: ^Test_ACP, method: settings.Approval_Method, withHome := false) {
	counter := sync.atomic_add(&testProviderCounter, 1)
	name := fmt.tprintf("acp-test-%d", counter)
	assert(session.fake_provider_start(&test.provider, name), "expected the fake provider to start")
	test.config = settings.default_ollama_config(context.allocator)
	clear(&test.config.providers)
	append(&test.config.providers, session.fake_provider_config(&test.provider))
	test.config.selectedProvider = test.provider.name
	test.config.selectedModel = session.FAKE_PROVIDER_MODEL
	test.config.approvalMethod = method
	test.config.safetyProvider = "acp-test-missing-provider"
	test.config.safetyModel = "acp-test-missing-model"
	test.directories = make([dynamic]string, 0, 4, context.allocator)
	test.lines = make([dynamic]string, 0, 64, context.allocator)
	if withHome {
		test.configHome = test_temp_directory(test, "acp-test-home-*")
	}
	test.conn = connection_init(&test.config, test.configHome)
	test.conn.logSink = test_discard_log
	test.nextClientID = 100
}

test_acp_destroy :: proc(test: ^Test_ACP) {
	connection_destroy(&test.conn)
	session.fake_provider_stop(&test.provider)
	for line in test.lines {
		delete(line)
	}
	delete(test.lines)
	for &grant in test.config.permissionGrants {
		tool_policy.permission_grant_destroy(&grant, context.allocator)
	}
	delete(test.config.providers)
	delete(test.config.disabledSkills)
	delete(test.config.permissionGrants)
	delete(test.config.contextWindows)
	for directory in test.directories {
		_ = os.remove_all(directory)
		delete(directory)
	}
	delete(test.directories)
}

// Makes a temporary directory that the test removes at the end.
test_temp_directory :: proc(test: ^Test_ACP, pattern: string) -> string {
	directory, err := os.make_directory_temp("", pattern, context.allocator)
	assert(err == nil, "expected a temporary directory")
	append(&test.directories, directory)
	return directory
}

// Moves the outbox into test.lines.
test_collect :: proc(test: ^Test_ACP) {
	for line in test.conn.outbox {
		append(&test.lines, line)
	}
	clear(&test.conn.outbox)
}

// Sends one inbound line and collects the output.
test_send :: proc(test: ^Test_ACP, line: string) {
	connection_handle_line(&test.conn, line)
	test_collect(test)
}

test_tick :: proc(test: ^Test_ACP) {
	connection_tick(&test.conn)
	test_collect(test)
}

// Returns outbound line index as an object.
test_message :: proc(test: ^Test_ACP, index: int) -> json.Object {
	value, err := json.parse_string(test.lines[index], .JSON, true, context.temp_allocator)
	assert(err == .None, fmt.tprintf("expected valid JSON, got %q", test.lines[index]))
	object, isObject := value.(json.Object)
	assert(isObject, "expected a JSON object")
	return object
}

// Returns the first response to request id at or after from, and its index.
test_find_response :: proc(test: ^Test_ACP, id: int, from := 0) -> (json.Object, int) {
	for index := from; index < len(test.lines); index += 1 {
		message := test_message(test, index)
		if _, hasMethod := message["method"]; hasMethod {
			continue
		}
		if messageID, ok := json_get_integer(message, "id"); ok && messageID == i64(id) {
			return message, index
		}
	}
	return nil, -1
}

// Returns the first request or notification with method at or after from, and its index.
test_find_method :: proc(test: ^Test_ACP, method: string, from := 0) -> (json.Object, int) {
	for index := from; index < len(test.lines); index += 1 {
		message := test_message(test, index)
		if messageMethod, ok := json_get_string(message, "method"); ok && messageMethod == method {
			return message, index
		}
	}
	return nil, -1
}

// Returns the first session/update of kind sessionUpdate at or after from, its index, and its
// session ID.
test_find_update :: proc(
	test: ^Test_ACP,
	sessionUpdate: string,
	from := 0,
	toolCallID := "",
) -> (
	json.Object,
	int,
) {
	for index := from; index < len(test.lines); index += 1 {
		message := test_message(test, index)
		method, _ := json_get_string(message, "method")
		if method != "session/update" {
			continue
		}
		params, _ := json_get_object(message, "params")
		update, _ := json_get_object(params, "update")
		kind, _ := json_get_string(update, "sessionUpdate")
		if kind != sessionUpdate {
			continue
		}
		if toolCallID != "" {
			id, _ := json_get_string(update, "toolCallId")
			if id != toolCallID {
				continue
			}
		}
		return update, index
	}
	return nil, -1
}

test_count_method :: proc(test: ^Test_ACP, method: string) -> int {
	count := 0
	for index := 0; index < len(test.lines); index += 1 {
		message := test_message(test, index)
		if messageMethod, ok := json_get_string(message, "method"); ok && messageMethod == method {
			count += 1
		}
	}
	return count
}

// Ticks until the response to request id arrives.
test_wait_response :: proc(test: ^Test_ACP, id: int) -> (json.Object, int) {
	start := time.tick_now()
	for {
		test_tick(test)
		if message, index := test_find_response(test, id); message != nil {
			return message, index
		}
		if time.tick_since(start) > TEST_TIMEOUT {
			test_dump(test)
			assert(false, fmt.tprintf("expected a response to request %d", id))
		}
		time.sleep(2 * time.Millisecond)
	}
}

// Ticks until a message with method arrives at or after from.
test_wait_method :: proc(test: ^Test_ACP, method: string, from := 0) -> (json.Object, int) {
	start := time.tick_now()
	for {
		test_tick(test)
		if message, index := test_find_method(test, method, from); message != nil {
			return message, index
		}
		if time.tick_since(start) > TEST_TIMEOUT {
			test_dump(test)
			assert(false, fmt.tprintf("expected a %s message", method))
		}
		time.sleep(2 * time.Millisecond)
	}
}

// Ticks until a session/update of kind sessionUpdate arrives at or after from.
test_wait_update :: proc(
	test: ^Test_ACP,
	sessionUpdate: string,
	from := 0,
	toolCallID := "",
) -> (
	json.Object,
	int,
) {
	start := time.tick_now()
	for {
		test_tick(test)
		if update, index := test_find_update(test, sessionUpdate, from, toolCallID);
		   update != nil {
			return update, index
		}
		if time.tick_since(start) > TEST_TIMEOUT {
			test_dump(test)
			assert(false, fmt.tprintf("expected a %s update", sessionUpdate))
		}
		time.sleep(2 * time.Millisecond)
	}
}

// Ticks for a while, so a test can check that nothing more is sent.
test_settle :: proc(test: ^Test_ACP) {
	for _ in 0 ..< 40 {
		test_tick(test)
		time.sleep(2 * time.Millisecond)
	}
}

test_dump :: proc(test: ^Test_ACP) {
	for line in test.lines {
		fmt.eprintln(line)
	}
}

test_next_id :: proc(test: ^Test_ACP) -> int {
	test.nextClientID += 1
	return test.nextClientID
}

test_initialize :: proc(test: ^Test_ACP, clientCapabilities := `{}`) {
	test_send(
		test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":0,"method":"initialize","params":{{"protocolVersion":1,"clientCapabilities":%s}}}}`,
			clientCapabilities,
		),
	)
	response, _ := test_find_response(test, 0)
	assert(response != nil, "expected the initialize response")
	_, hasResult := response["result"]
	assert(hasResult, "expected an initialize result")
}

// Creates an ACP session in cwd (a new temporary directory when cwd is "") and returns its ID.
test_new_session :: proc(test: ^Test_ACP, cwd := "") -> string {
	cwd := cwd
	if cwd == "" {
		cwd = test_temp_directory(test, "acp-test-root-*")
	}
	id := test_next_id(test)
	test_send(
		test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"session/new","params":{{"cwd":%s,"mcpServers":[]}}}}`,
			id,
			test_json_string(cwd),
		),
	)
	response, _ := test_find_response(test, id)
	assert(response != nil, "expected the session/new response")
	result, resultOK := json_get_object(response, "result")
	assert(resultOK, fmt.tprintf("expected a session/new result, got %v", response))
	sessionID, sessionOK := json_get_string(result, "sessionId")
	assert(sessionOK, "expected a sessionId")
	return strings.clone(sessionID, context.temp_allocator)
}

test_json_string :: proc(text: string) -> string {
	line, ok := json_marshal_line(json.String(text), context.temp_allocator)
	assert(ok, "expected a JSON string")
	return line
}

// Sends session/prompt with one text block and returns the request ID.
test_prompt :: proc(test: ^Test_ACP, sessionID, text: string) -> int {
	id := test_next_id(test)
	test_send(
		test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"method":"session/prompt","params":{{"sessionId":%s,"prompt":[{{"type":"text","text":%s}}]}}}}`,
			id,
			test_json_string(sessionID),
			test_json_string(text),
		),
	)
	return id
}

// Answers a permission request with outcome JSON, for example a selected option.
test_answer_permission :: proc(test: ^Test_ACP, request: json.Object, outcome: string) {
	requestID, ok := json_get_integer(request, "id")
	assert(ok, "expected a permission request ID")
	test_send(
		test,
		fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"outcome":%s}}}}`, requestID, outcome),
	)
}

test_select_option :: proc(test: ^Test_ACP, request: json.Object, optionID: string) {
	test_answer_permission(
		test,
		request,
		fmt.tprintf(`{{"outcome":"selected","optionId":"%s"}}`, optionID),
	)
}

test_stop_reason :: proc(response: json.Object) -> string {
	result, _ := json_get_object(response, "result")
	reason, _ := json_get_string(result, "stopReason")
	return reason
}

test_error_code :: proc(response: json.Object) -> i64 {
	errorObject, _ := json_get_object(response, "error")
	code, _ := json_get_integer(errorObject, "code")
	return code
}

// Returns the option IDs of a permission request.
test_option_ids :: proc(request: json.Object) -> []string {
	params, _ := json_get_object(request, "params")
	options, _ := json_get_array(params, "options")
	ids := make([dynamic]string, 0, len(options), context.temp_allocator)
	for option in options {
		object, _ := option.(json.Object)
		optionID, _ := json_get_string(object, "optionId")
		append(&ids, optionID)
	}
	return ids[:]
}

test_strings_equal :: proc(actual: []string, expected: ..string) -> bool {
	if len(actual) != len(expected) {
		return false
	}
	for value, index in actual {
		if value != expected[index] {
			return false
		}
	}
	return true
}

// Returns the texts of the text content blocks of a tool call or update, joined by "\n".
test_content_text :: proc(object: json.Object) -> string {
	content, _ := json_get_array(object, "content")
	builder := strings.builder_make(context.temp_allocator)
	for block in content {
		blockObject, _ := block.(json.Object)
		inner, innerOK := json_get_object(blockObject, "content")
		if !innerOK {
			continue
		}
		text, _ := json_get_string(inner, "text")
		if strings.builder_len(builder) > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, text)
	}
	return strings.to_string(builder)
}

// Returns the folder name of a test root. Each root has a unique name. A pwd check compares the
// name, not the path: on Windows the temporary directory can be a short 8.3 path, and the shell
// prints the long path.
test_root_name :: proc(root: string) -> string {
	return filepath.base(root)
}

// Returns the stdout field of the run_in_terminal result in text, or text itself when it has
// no terminal result (for example an error message). The tool call content can hold other
// blocks, such as the safety text, before the result. The result is JSON, so a Windows path in
// it has escaped backslashes; the decoded field has the path as the command printed it.
test_terminal_stdout :: proc(text: string) -> string {
	start := strings.index(text, `{"stdout"`)
	if start == -1 {
		return text
	}
	value, parseErr := json.parse_string(text[start:], allocator = context.temp_allocator)
	if parseErr != nil {
		return text
	}
	object, objectOK := value.(json.Object)
	if !objectOK {
		return text
	}
	stdout, stdoutOK := object["stdout"].(json.String)
	if !stdoutOK {
		return text
	}
	return stdout
}

test_queue_tool_turn :: proc(test: ^Test_ACP, toolName, argumentsJSON: string) {
	session.fake_provider_add_response(
		&test.provider,
		false,
		session.fake_provider_tool_call_line(toolName, argumentsJSON),
		session.fake_provider_text_line("", true),
	)
}

test_queue_text :: proc(test: ^Test_ACP, text: string) {
	session.fake_provider_add_response(
		&test.provider,
		false,
		session.fake_provider_text_line(text, true),
	)
}

@(test)
test_acp_initialize_reports_version_and_capabilities :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)

	test_send(&test, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}`)
	early, _ := test_find_response(&test, 1)
	assert(test_error_code(early) == ERROR_INVALID_REQUEST, "expected -32600 before initialize")

	test_send(
		&test,
		`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":7}}`,
	)
	response, _ := test_find_response(&test, 2)
	result, resultOK := json_get_object(response, "result")
	assert(resultOK, "expected an initialize result")
	version, _ := json_get_integer(result, "protocolVersion")
	assert(version == 1, "expected protocol version 1 for any requested version")
	capabilities, _ := json_get_object(result, "agentCapabilities")
	loadSession, _ := capabilities["loadSession"].(json.Boolean)
	assert(!loadSession, "expected loadSession to be false")
	promptCapabilities, _ := json_get_object(capabilities, "promptCapabilities")
	embedded, _ := promptCapabilities["embeddedContext"].(json.Boolean)
	assert(!embedded, "expected no embedded context")
	sessionCapabilities, _ := json_get_object(capabilities, "sessionCapabilities")
	_, hasClose := json_get_object(sessionCapabilities, "close")
	assert(hasClose, "expected sessionCapabilities.close")
	authMethods, _ := json_get_array(result, "authMethods")
	assert(len(authMethods) == 0, "expected no auth methods")
	agentInfo, _ := json_get_object(result, "agentInfo")
	name, _ := json_get_string(agentInfo, "name")
	assert(name == "mimir", "expected the agent name")

	test_send(
		&test,
		`{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":1}}`,
	)
	second, _ := test_find_response(&test, 3)
	assert(
		test_error_code(second) == ERROR_INVALID_REQUEST,
		"expected -32600 for a second initialize",
	)
	_ = t
}

@(test)
test_acp_reports_protocol_errors :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)

	test_send(&test, `{not json`)
	parseError := test_message(&test, len(test.lines) - 1)
	assert(test_error_code(parseError) == ERROR_PARSE, "expected -32700 for invalid JSON")
	_, isNull := parseError["id"].(json.Null)
	assert(isNull, "expected id null for a parse error")

	test_send(&test, `[{"jsonrpc":"2.0","id":5,"method":"initialize"}]`)
	batch := test_message(&test, len(test.lines) - 1)
	assert(test_error_code(batch) == ERROR_INVALID_REQUEST, "expected -32600 for a batch")

	test_send(&test, `{"jsonrpc":"2.0","id":6,"method":"session/load","params":{}}`)
	unknown, _ := test_find_response(&test, 6)
	assert(test_error_code(unknown) == ERROR_METHOD_NOT_FOUND, "expected -32601 for session/load")
	test_send(&test, `{"jsonrpc":"2.0","id":7,"method":"_mimir/extension","params":{}}`)
	extension, _ := test_find_response(&test, 7)
	assert(test_error_code(extension) == ERROR_METHOD_NOT_FOUND, "expected -32601 for extensions")

	before := len(test.lines)
	test_send(&test, `{"jsonrpc":"2.0","method":"_mimir/unknown","params":{}}`)
	assert(len(test.lines) == before, "expected unknown notifications to be ignored")

	test_send(
		&test,
		`{"jsonrpc":"2.0","id":8,"method":"session/prompt","params":{"sessionId":"sess_9","prompt":[{"type":"text","text":"hi"}]}}`,
	)
	missing, _ := test_find_response(&test, 8)
	assert(test_error_code(missing) == ERROR_RESOURCE_NOT_FOUND, "expected -32002")
	errorObject, _ := json_get_object(missing, "error")
	data, _ := json_get_object(errorObject, "data")
	missingID, _ := json_get_string(data, "sessionId")
	assert(missingID == "sess_9", "expected data.sessionId")

	connection_handle_oversized_line(&test.conn)
	test_collect(&test)
	oversized := test_message(&test, len(test.lines) - 1)
	assert(test_error_code(oversized) == ERROR_PARSE, "expected -32700 for an oversized line")
	_ = t
}

@(test)
test_acp_session_new_validates_params :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	root := test_temp_directory(&test, "acp-test-root-*")
	missingRoot := strings.concatenate({root, "/missing"}, context.temp_allocator)

	cases := []string {
		`{"cwd":"relative/path","mcpServers":[]}`,
		`{"mcpServers":[]}`,
		fmt.tprintf(`{{"cwd":%s,"mcpServers":[]}}`, test_json_string(missingRoot)),
		fmt.tprintf(`{{"cwd":%s}}`, test_json_string(root)),
		fmt.tprintf(
			`{{"cwd":%s,"mcpServers":[],"additionalDirectories":["/tmp"]}}`,
			test_json_string(root),
		),
		fmt.tprintf(
			`{{"cwd":%s,"mcpServers":[],"systemPrompt":"Be brief"}}`,
			test_json_string(root),
		),
	}
	for params, index in cases {
		id := 10 + index
		test_send(
			&test,
			fmt.tprintf(
				`{{"jsonrpc":"2.0","id":%d,"method":"session/new","params":%s}}`,
				id,
				params,
			),
		)
		response, _ := test_find_response(&test, id)
		assert(
			response != nil && test_error_code(response) == ERROR_INVALID_PARAMS,
			fmt.tprintf("expected -32602 for %s", params),
		)
	}
	assert(len(test.conn.sessions) == 0, "expected no session for invalid params")
	_ = t
}

@(test)
test_acp_session_new_without_usable_model_fails :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test.config.providers[0].enabled = false
	test_initialize(&test)
	root := test_temp_directory(&test, "acp-test-root-*")
	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":5,"method":"session/new","params":{{"cwd":%s,"mcpServers":[]}}}}`,
			test_json_string(root),
		),
	)
	response, _ := test_find_response(&test, 5)
	assert(test_error_code(response) == ERROR_NO_USABLE_MODEL, "expected -31002")
	_ = t
}

@(test)
test_acp_session_new_ignores_mcp_servers_with_a_notice :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test, `{"session":{"notices":{}}}`)
	root := test_temp_directory(&test, "acp-test-root-*")
	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":5,"method":"session/new","params":{{"cwd":%s,"mcpServers":[{{"name":"files","command":"files-mcp","args":[],"env":[]}}]}}}}`,
			test_json_string(root),
		),
	)
	response, responseIndex := test_find_response(&test, 5)
	_, resultOK := json_get_object(response, "result")
	assert(resultOK, "expected the session to be created")
	notice, noticeIndex := test_find_update(&test, "notice")
	assert(notice != nil && noticeIndex > responseIndex, "expected a notice after the response")
	severity, _ := json_get_string(notice, "severity")
	title, _ := json_get_string(notice, "title")
	assert(severity == "warning", "expected a warning notice")
	assert(strings.contains(title, "files"), "expected the ignored server name")
	_ = t
}

@(test)
test_acp_prompt_streams_text_and_ends_turn :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	append(
		&test.config.contextWindows,
		settings.Context_Window_Config {
			providerName = test.provider.name,
			model = session.FAKE_PROVIDER_MODEL,
			tokens = 4096,
		},
	)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	session.fake_provider_add_response(
		&test.provider,
		false,
		session.fake_provider_text_line("Hello "),
		session.fake_provider_text_line("world"),
		session.fake_provider_text_line("", true),
	)

	id := test_prompt(&test, sessionID, "hi")
	response, responseIndex := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")

	builder := strings.builder_make(context.temp_allocator)
	lastUpdate := -1
	for index := 0; index < len(test.lines); index += 1 {
		message := test_message(&test, index)
		if method, _ := json_get_string(message, "method"); method != "session/update" {
			continue
		}
		lastUpdate = index
		params, _ := json_get_object(message, "params")
		updateSession, _ := json_get_string(params, "sessionId")
		assert(updateSession == sessionID, "expected the session ID on every update")
		update, _ := json_get_object(params, "update")
		if kind, _ := json_get_string(update, "sessionUpdate"); kind == "agent_message_chunk" {
			content, _ := json_get_object(update, "content")
			text, _ := json_get_string(content, "text")
			strings.write_string(&builder, text)
		}
	}
	assert(strings.to_string(builder) == "Hello world", "expected the streamed text")
	assert(lastUpdate < responseIndex, "expected every update before the response")
	usage, _ := test_find_update(&test, "usage_update")
	assert(usage != nil, "expected a usage update with a known context window")
	size, _ := json_get_integer(usage, "size")
	assert(size == 4096, "expected the context window size")
	_ = t
}

@(test)
test_acp_prompt_rejects_unsupported_content :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{{"sessionId":%s,"prompt":[{{"type":"image","data":"","mimeType":"image/png"}}]}}}}`,
			test_json_string(sessionID),
		),
	)
	response, _ := test_find_response(&test, 5)
	assert(test_error_code(response) == ERROR_INVALID_PARAMS, "expected -32602 for an image")
	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":6,"method":"session/prompt","params":{{"sessionId":%s,"prompt":[]}}}}`,
			test_json_string(sessionID),
		),
	)
	empty, _ := test_find_response(&test, 6)
	assert(test_error_code(empty) == ERROR_INVALID_PARAMS, "expected -32602 for an empty prompt")
	_ = t
}

@(test)
test_acp_prompt_text_writes_resource_links :: proc(t: ^testing.T) {
	root := "/work/project"
	value, err := json.parse_string(
		`[{"type":"text","text":"Read"},{"type":"resource_link","uri":"file:///work/project/src/main%20file.odin","name":"main file.odin"},{"type":"resource_link","uri":"https://example.com/doc","name":"Doc"},{"type":"text","text":"please"}]`,
		.JSON,
		true,
		context.temp_allocator,
	)
	assert(err == .None, "expected valid test JSON")
	text, ok, _ := prompt_text(root, value.(json.Array))
	assert(ok, "expected text and resource_link blocks")
	expected := "Read\n@src/main file.odin\n@https://example.com/doc (Doc)\nplease"
	assert(text == expected, fmt.tprintf("expected %q, got %q", expected, text))
	_ = t
}

@(test)
test_acp_second_prompt_is_busy :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	session.fake_provider_add_response(
		&test.provider,
		true,
		session.fake_provider_text_line("working"),
	)

	first := test_prompt(&test, sessionID, "first")
	_, _ = test_wait_update(&test, "agent_message_chunk")
	second := test_prompt(&test, sessionID, "second")
	busy, _ := test_find_response(&test, second)
	assert(test_error_code(busy) == ERROR_SESSION_BUSY, "expected -31001 for a second prompt")

	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"session/cancel","params":{{"sessionId":%s}}}}`,
			test_json_string(sessionID),
		),
	)
	response, _ := test_wait_response(&test, first)
	assert(test_stop_reason(response) == "cancelled", "expected the first prompt to be cancelled")
	_ = t
}

@(test)
test_acp_cancel_request_for_the_prompt_cancels_it :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	session.fake_provider_add_response(
		&test.provider,
		true,
		session.fake_provider_text_line("working"),
	)

	id := test_prompt(&test, sessionID, "go")
	_, _ = test_wait_update(&test, "agent_message_chunk")
	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"$/cancel_request","params":{{"requestId":%d}}}}`,
			id,
		),
	)
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "cancelled", "expected cancelled")
	_ = t
}

// Runs a prompt that asks to run pwd and returns the permission request.
test_request_pwd_permission :: proc(test: ^Test_ACP, sessionID: string) -> (int, json.Object) {
	test_queue_tool_turn(test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_text(test, "ok")
	from := len(test.lines)
	id := test_prompt(test, sessionID, "run pwd")
	request, requestIndex := test_wait_method(test, "session/request_permission", from)
	toolCall, toolCallIndex := test_find_update(test, "tool_call", from)
	assert(
		toolCall != nil && toolCallIndex < requestIndex,
		"expected the tool call before the permission request",
	)
	status, _ := json_get_string(toolCall, "status")
	assert(status == "pending", "expected a pending tool call")
	kind, _ := json_get_string(toolCall, "kind")
	assert(kind == "execute", "expected the execute kind")
	return id, request
}

@(test)
test_acp_permission_allow_once_runs_the_tool :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	id, request := test_request_pwd_permission(&test, sessionID)
	params, _ := json_get_object(request, "params")
	requestSession, _ := json_get_string(params, "sessionId")
	assert(requestSession == sessionID, "expected the session ID on the request")
	assert(
		test_strings_equal(
			test_option_ids(request),
			"allow-once",
			"allow-session",
			"allow-always",
			"reject-once",
		),
		"expected the four options for a command in the project root",
	)
	options, _ := json_get_array(params, "options")
	sessionOption, _ := options[1].(json.Object)
	sessionName, _ := json_get_string(sessionOption, "name")
	sessionKind, _ := json_get_string(sessionOption, "kind")
	assert(
		sessionName == "Allow for this session: commands starting with pwd",
		"expected the scope in the option name",
	)
	assert(sessionKind == "allow_always", "expected allow_always for a session grant")
	toolCall, _ := json_get_object(params, "toolCall")
	safety := test_content_text(toolCall)
	assert(strings.contains(safety, "Safety check: unavailable."), "expected the safety text")

	test_select_option(&test, request, "allow-once")
	response, responseIndex := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	completed, completedIndex := test_find_update(&test, "tool_call_update", 0, toolCallID)
	for completed != nil {
		status, _ := json_get_string(completed, "status")
		if status == "completed" {
			break
		}
		completed, completedIndex = test_find_update(
			&test,
			"tool_call_update",
			completedIndex + 1,
			toolCallID,
		)
	}
	assert(completed != nil && completedIndex < responseIndex, "expected the tool to complete")
	output := test_content_text(completed)
	root := test_root_name(test.directories[len(test.directories) - 1])
	assert(
		strings.contains(test_terminal_stdout(output), root),
		fmt.tprintf("expected pwd to run in the session cwd %q, got %q", root, output),
	)
	assert(len(test.config.permissionGrants) == 0, "expected no grant for allow-once")
	_ = t
}

@(test)
test_acp_permission_reject_and_unknown_options_deny :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)

	outcomes := []string {
		`{"outcome":"selected","optionId":"reject-once"}`,
		`{"outcome":"selected","optionId":"allow-everything"}`,
		`{"outcome":"something-new"}`,
		`{"outcome":"cancelled"}`,
	}
	for outcome in outcomes {
		id, request := test_request_pwd_permission(&test, sessionID)
		params, _ := json_get_object(request, "params")
		toolCall, _ := json_get_object(params, "toolCall")
		toolCallID, _ := json_get_string(toolCall, "toolCallId")
		from := len(test.lines)
		test_answer_permission(&test, request, outcome)
		response, _ := test_wait_response(&test, id)
		assert(test_stop_reason(response) == "end_turn", "expected the agent to go on")
		denied, _ := test_find_update(&test, "tool_call_update", from, toolCallID)
		assert(denied != nil, "expected a tool call update")
		status, _ := json_get_string(denied, "status")
		assert(status == "failed", fmt.tprintf("expected %s to deny the call", outcome))
		assert(
			test_content_text(denied) == "Safety check: unavailable.\nPermission denied.",
			fmt.tprintf("expected the denial text, got %q", test_content_text(denied)),
		)
	}
	_ = t
}

@(test)
test_acp_permission_allow_always_saves_the_grant :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask, true)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	id, request := test_request_pwd_permission(&test, sessionID)
	test_select_option(&test, request, "allow-always")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	assert(len(test.config.permissionGrants) == 1, "expected a config grant")
	assert(test.config.permissionGrants[0].command == "pwd", "expected the command grant")
	path := settings.config_path(test.configHome, context.temp_allocator)
	data, readErr := os.read_entire_file(path, context.temp_allocator)
	assert(readErr == nil, "expected the config file to be saved")
	assert(strings.contains(string(data), "pwd"), "expected the grant in the config file")

	// The grant is persistent, so another session in the same root needs no request either.
	root := test.directories[len(test.directories) - 1]
	other := test_new_session(&test, root)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_text(&test, "ok")
	requestsBefore := test_count_method(&test, "session/request_permission")
	otherID := test_prompt(&test, other, "again")
	_, _ = test_wait_response(&test, otherID)
	assert(
		test_count_method(&test, "session/request_permission") == requestsBefore,
		"expected no request after allow-always",
	)
	_ = t
}

@(test)
test_acp_two_sessions_keep_their_cwd_and_session_grants :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	first := test_new_session(&test)
	firstRoot := test.directories[len(test.directories) - 1]
	second := test_new_session(&test)
	secondRoot := test.directories[len(test.directories) - 1]
	assert(first != second, "expected different session IDs")

	id, request := test_request_pwd_permission(&test, first)
	test_select_option(&test, request, "allow-session")
	_, _ = test_wait_response(&test, id)

	// The session grant applies to the first session only.
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_text(&test, "ok")
	from := len(test.lines)
	againID := test_prompt(&test, first, "again")
	_, _ = test_wait_response(&test, againID)
	_, noRequest := test_find_method(&test, "session/request_permission", from)
	assert(noRequest == -1, "expected allow-session to cover the second call")
	toolCall, _ := test_find_update(&test, "tool_call", from)
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	output := ""
	for index := from; index < len(test.lines); index += 1 {
		if update, updateIndex := test_find_update(&test, "tool_call_update", index, toolCallID);
		   update != nil {
			if text := test_content_text(update); text != "" {
				output = text
			}
			index = updateIndex
		}
	}
	assert(
		strings.contains(test_terminal_stdout(output), test_root_name(firstRoot)),
		fmt.tprintf("expected pwd in the first root %q, got %q", firstRoot, output),
	)

	secondID, secondRequest := test_request_pwd_permission(&test, second)
	params, _ := json_get_object(secondRequest, "params")
	requestSession, _ := json_get_string(params, "sessionId")
	assert(requestSession == second, "expected the request of the second session")
	test_select_option(&test, secondRequest, "allow-once")
	_, secondResponseIndex := test_wait_response(&test, secondID)
	secondOutput := ""
	for index := 0; index < secondResponseIndex; index += 1 {
		message := test_message(&test, index)
		paramsObject, _ := json_get_object(message, "params")
		if updateSession, _ := json_get_string(paramsObject, "sessionId"); updateSession != second {
			continue
		}
		update, _ := json_get_object(paramsObject, "update")
		if kind, _ := json_get_string(update, "sessionUpdate"); kind == "tool_call_update" {
			if text := test_content_text(update); strings.contains(text, "stdout") {
				secondOutput = text
			}
		}
	}
	secondStdout := test_terminal_stdout(secondOutput)
	assert(
		strings.contains(secondStdout, test_root_name(secondRoot)),
		fmt.tprintf("expected pwd in the second root %q, got %q", secondRoot, secondOutput),
	)
	assert(
		!strings.contains(secondStdout, test_root_name(firstRoot)),
		"expected separate project roots",
	)
	_ = t
}

@(test)
test_acp_tool_call_ids_stay_unique_across_responses :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_All)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	// Both responses number their tool call ollama-0.
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_tool_turn(&test, "run_in_terminal", `{"command":"ls"}`)
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "run")
	_, _ = test_wait_response(&test, id)
	first, firstIndex := test_find_update(&test, "tool_call")
	second, _ := test_find_update(&test, "tool_call", firstIndex + 1)
	assert(first != nil && second != nil, "expected two tool calls")
	firstID, _ := json_get_string(first, "toolCallId")
	secondID, _ := json_get_string(second, "toolCallId")
	assert(firstID != secondID, fmt.tprintf("expected unique IDs, got %s twice", firstID))
	assert(
		test_count_method(&test, "session/request_permission") == 0,
		"expected Approve_All to ask nothing",
	)
	_ = t
}

@(test)
test_acp_write_file_sends_a_diff :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_All)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	root := test.directories[len(test.directories) - 1]
	test_queue_tool_turn(
		&test,
		"write_file",
		`{"file_path":"notes.md","content":"hello\n","overwrite":"false"}`,
	)
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "write")
	_, _ = test_wait_response(&test, id)
	toolCall, _ := test_find_update(&test, "tool_call")
	kind, _ := json_get_string(toolCall, "kind")
	assert(kind == "edit", "expected the edit kind")
	path, _ := os.join_path({root, "notes.md"}, context.temp_allocator)
	locations, _ := json_get_array(toolCall, "locations")
	assert(len(locations) == 1, "expected one location")
	location, _ := locations[0].(json.Object)
	locationPath, _ := json_get_string(location, "path")
	assert(locationPath == path, "expected the absolute path as the location")

	diff: json.Object
	for index := 0; index < len(test.lines) && diff == nil; index += 1 {
		update, updateIndex := test_find_update(&test, "tool_call_update", index)
		if update == nil {
			break
		}
		index = updateIndex
		content, _ := json_get_array(update, "content")
		for block in content {
			object, _ := block.(json.Object)
			if blockType, _ := json_get_string(object, "type"); blockType == "diff" {
				diff = object
			}
		}
	}
	assert(diff != nil, "expected diff content")
	diffPath, _ := json_get_string(diff, "path")
	newText, _ := json_get_string(diff, "newText")
	_, oldIsNull := diff["oldText"].(json.Null)
	assert(diffPath == path, "expected the absolute diff path")
	assert(newText == "hello\n", "expected the whole new text")
	assert(oldIsNull, "expected oldText null for a new file")
	_ = t
}

@(test)
test_acp_subagent_text_is_content_of_its_tool_call :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_All)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Count files","tools":["find_code"]}`)
	test_queue_text(&test, "child answer")
	test_queue_text(&test, "parent done")

	id := test_prompt(&test, sessionID, "delegate")
	response, responseIndex := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	toolCall, _ := test_find_update(&test, "tool_call")
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	name, _ := json_get_string(toolCall, "kind")
	assert(name == "other", "expected the other kind for run_subagent")

	last: json.Object
	lastIndex := -1
	for {
		update, index := test_find_update(&test, "tool_call_update", lastIndex + 1, toolCallID)
		if update == nil {
			break
		}
		last, lastIndex = update, index
	}
	assert(last != nil && lastIndex < responseIndex, "expected run_subagent updates")
	status, _ := json_get_string(last, "status")
	assert(status == "completed", "expected the subagent call to complete")
	text := test_content_text(last)
	assert(strings.contains(text, "Task: Count files"), "expected the task")
	assert(strings.contains(text, "child answer"), "expected the subagent text and result")

	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(test.lines); index += 1 {
		chunk, chunkIndex := test_find_update(&test, "agent_message_chunk", index)
		if chunk == nil {
			break
		}
		index = chunkIndex
		content, _ := json_get_object(chunk, "content")
		chunkText, _ := json_get_string(content, "text")
		strings.write_string(&builder, chunkText)
	}
	assert(strings.to_string(builder) == "parent done", "expected only parent text as chunks")
	_ = t
}

@(test)
test_acp_cancel_during_a_subagent_ends_the_prompt :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_All)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Wait","tools":["find_code"]}`)
	session.fake_provider_add_response(
		&test.provider,
		true,
		session.fake_provider_text_line("child working"),
	)

	id := test_prompt(&test, sessionID, "delegate")
	toolCall, _ := test_wait_update(&test, "tool_call")
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	// Wait until the subagent text arrives as content of the run_subagent call.
	start := time.tick_now()
	for {
		test_tick(&test)
		found := false
		for index := 0; index < len(test.lines); index += 1 {
			update, updateIndex := test_find_update(&test, "tool_call_update", index, toolCallID)
			if update == nil {
				break
			}
			index = updateIndex
			if strings.contains(test_content_text(update), "child working") {
				found = true
			}
		}
		if found {
			break
		}
		assert(time.tick_since(start) < TEST_TIMEOUT, "expected the subagent to stream")
		time.sleep(2 * time.Millisecond)
	}

	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"session/cancel","params":{{"sessionId":%s}}}}`,
			test_json_string(sessionID),
		),
	)
	response, responseIndex := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "cancelled", "expected cancelled during a subagent")
	last: json.Object
	lastIndex := -1
	for {
		update, index := test_find_update(&test, "tool_call_update", lastIndex + 1, toolCallID)
		if update == nil {
			break
		}
		last, lastIndex = update, index
	}
	status, _ := json_get_string(last, "status")
	assert(status == "failed" && lastIndex < responseIndex, "expected the call to fail first")
	test_settle(&test)
	for index := responseIndex + 1; index < len(test.lines); index += 1 {
		message := test_message(&test, index)
		method, _ := json_get_string(message, "method")
		assert(method != "session/update", "expected no update after the prompt response")
	}
	_ = t
}

@(test)
test_acp_cancel_with_an_open_permission_request :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	id, request := test_request_pwd_permission(&test, sessionID)

	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"session/cancel","params":{{"sessionId":%s}}}}`,
			test_json_string(sessionID),
		),
	)
	response, responseIndex := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "cancelled", "expected cancelled")
	_, cancelIndex := test_find_method(&test, "$/cancel_request")
	assert(cancelIndex == -1, "expected no $/cancel_request after session/cancel")

	// The client answers the open request with cancelled, as ACP requires. It is ignored.
	test_answer_permission(&test, request, `{"outcome":"cancelled"}`)
	test_settle(&test)
	assert(len(test.lines) == responseIndex + 1, "expected nothing after the late response")
	assert(len(test.conn.outbound) == 0, "expected no open permission request")

	// The session takes a new prompt.
	test_queue_text(&test, "again")
	next := test_prompt(&test, sessionID, "next")
	nextResponse, _ := test_wait_response(&test, next)
	assert(test_stop_reason(nextResponse) == "end_turn", "expected the next prompt to run")
	_ = t
}

// Selects the fake provider as the safety model.
test_use_fake_safety_model :: proc(test: ^Test_ACP) {
	test.config.safetyProvider = test.provider.name
	test.config.safetyModel = session.FAKE_PROVIDER_MODEL
}

@(test)
test_acp_approve_safe_auto_approval_sends_no_request :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_Safe)
	defer test_acp_destroy(&test)
	test_use_fake_safety_model(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_text(&test, "SAFE|Prints the working directory.")
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "run")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	assert(
		test_count_method(&test, "session/request_permission") == 0,
		"expected the safe call to run without asking",
	)
	_ = t
}

@(test)
test_acp_approve_safe_holds_the_request_until_the_verdict :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_Safe)
	defer test_acp_destroy(&test)
	test_use_fake_safety_model(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	session.fake_provider_add_delayed_response(
		&test.provider,
		400 * time.Millisecond,
		session.fake_provider_text_line("RISKY|Could do anything.", true),
	)
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "run")
	_, _ = test_wait_update(&test, "tool_call")
	entry := test.conn.sessions[sessionID]
	start := time.tick_now()
	for !entry.approval.held {
		test_tick(&test)
		assert(time.tick_since(start) < TEST_TIMEOUT, "expected the request to be held")
		time.sleep(2 * time.Millisecond)
	}
	assert(
		test_count_method(&test, "session/request_permission") == 0,
		"expected no request while the verdict is pending",
	)
	request, _ := test_wait_method(&test, "session/request_permission")
	params, _ := json_get_object(request, "params")
	toolCall, _ := json_get_object(params, "toolCall")
	text := test_content_text(toolCall)
	assert(
		strings.contains(text, "Safety check: risky. Could do anything."),
		fmt.tprintf("expected the verdict in the request, got %q", text),
	)
	test_select_option(&test, request, "reject-once")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	_ = t
}

@(test)
test_acp_approve_safe_late_approval_cancels_the_open_request :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Approve_Safe)
	defer test_acp_destroy(&test)
	// The hold runs out at once, so the request is open when the safe verdict arrives.
	test.conn.safetyHoldTimeout = 0
	test_use_fake_safety_model(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	session.fake_provider_add_delayed_response(
		&test.provider,
		400 * time.Millisecond,
		session.fake_provider_text_line("SAFE|Prints the working directory.", true),
	)
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "run")
	request, requestIndex := test_wait_method(&test, "session/request_permission")
	cancel, cancelIndex := test_wait_method(&test, "$/cancel_request", requestIndex)
	assert(cancelIndex > requestIndex, "expected $/cancel_request after the request")
	cancelParams, _ := json_get_object(cancel, "params")
	cancelID, _ := json_get_integer(cancelParams, "requestId")
	requestID, _ := json_get_integer(request, "id")
	assert(cancelID == requestID, "expected the request ID in $/cancel_request")

	// The client's late answer must not apply to anything.
	test_select_option(&test, request, "reject-once")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	params, _ := json_get_object(request, "params")
	toolCall, _ := json_get_object(params, "toolCall")
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	completed := false
	for index := 0; index < len(test.lines); index += 1 {
		update, updateIndex := test_find_update(&test, "tool_call_update", index, toolCallID)
		if update == nil {
			break
		}
		index = updateIndex
		if status, _ := json_get_string(update, "status"); status == "completed" {
			completed = true
		}
	}
	assert(completed, "expected the automatically approved call to run")
	_ = t
}

@(test)
test_acp_session_close_cancels_and_destroys_the_session :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	session.fake_provider_add_response(
		&test.provider,
		true,
		session.fake_provider_text_line("working"),
	)
	promptID := test_prompt(&test, sessionID, "go")
	_, _ = test_wait_update(&test, "agent_message_chunk")

	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":50,"method":"session/close","params":{{"sessionId":%s}}}}`,
			test_json_string(sessionID),
		),
	)
	closed, closedIndex := test_wait_response(&test, 50)
	_, hasResult := json_get_object(closed, "result")
	assert(hasResult, "expected an empty close result")
	prompt, promptIndex := test_find_response(&test, promptID)
	assert(test_stop_reason(prompt) == "cancelled", "expected the prompt to be cancelled")
	assert(promptIndex < closedIndex, "expected the prompt response before the close response")
	assert(len(test.conn.sessions) == 0, "expected the session to be destroyed")

	test_send(
		&test,
		fmt.tprintf(
			`{{"jsonrpc":"2.0","id":51,"method":"session/close","params":{{"sessionId":%s}}}}`,
			test_json_string(sessionID),
		),
	)
	again, _ := test_find_response(&test, 51)
	_, againResult := json_get_object(again, "result")
	assert(againResult, "expected closing again to succeed")
	_ = t
}

@(test)
test_acp_shutdown_answers_an_open_prompt :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	session.fake_provider_add_response(
		&test.provider,
		true,
		session.fake_provider_text_line("working"),
	)
	promptID := test_prompt(&test, sessionID, "go")
	_, _ = test_wait_update(&test, "agent_message_chunk")

	connection_shutdown(&test.conn)
	test_collect(&test)
	response, _ := test_find_response(&test, promptID)
	assert(test_stop_reason(response) == "cancelled", "expected the open prompt to be answered")
	assert(len(test.conn.sessions) == 0, "expected every session to be destroyed")
	_ = t
}

@(test)
test_acp_failed_turn_is_an_error_unless_canceled :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	// A response that is not Ollama JSON makes the stream fail.
	session.fake_provider_add_response(&test.provider, false, "not json")
	id := test_prompt(&test, sessionID, "hi")
	response, _ := test_wait_response(&test, id)
	assert(test_error_code(response) == ERROR_INTERNAL, "expected -32603 for a failed turn")
	errorObject, _ := json_get_object(response, "error")
	data, _ := json_get_object(errorObject, "data")
	dataSession, _ := json_get_string(data, "sessionId")
	assert(dataSession == sessionID, "expected data.sessionId")

	// After session/cancel, a failure (for example an aborted request) is cancelled.
	session.fake_provider_add_response(&test.provider, false, "not json")
	canceled := test_prompt(&test, sessionID, "again")
	test.conn.sessions[sessionID].cancelRequested = true
	canceledResponse, _ := test_wait_response(&test, canceled)
	assert(test_stop_reason(canceledResponse) == "cancelled", "expected cancelled after a cancel")
	_ = t
}

@(test)
test_acp_unsaved_grant_asks_again_with_one_time_options :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask, true)
	defer test_acp_destroy(&test)
	// A regular file where the config directory should be makes the save fail.
	blocker := strings.concatenate({test.configHome, "/.config"}, context.temp_allocator)
	assert(os.write_entire_file(blocker, "") == nil, "expected a config directory blocker")
	test_initialize(&test)
	sessionID := test_new_session(&test)
	id, request := test_request_pwd_permission(&test, sessionID)
	requestID, _ := json_get_integer(request, "id")

	from := len(test.lines)
	test_select_option(&test, request, "allow-always")
	again, _ := test_find_method(&test, "session/request_permission", from)
	assert(again != nil, "expected a new permission request")
	againID, _ := json_get_integer(again, "id")
	assert(againID != requestID, "expected a new request ID")
	assert(
		test_strings_equal(test_option_ids(again), "allow-once", "reject-once"),
		"expected only one-time options after a failed save",
	)
	assert(len(test.config.permissionGrants) == 0, "expected no grant")
	// A grant option that was not offered counts as unknown and denies.
	test_select_option(&test, again, "allow-session")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected the agent to go on")
	assert(len(test.config.permissionGrants) == 0, "expected no grant from a hidden option")
	_ = t
}

@(test)
test_acp_always_ask_sends_a_late_verdict_as_a_tool_call_update :: proc(t: ^testing.T) {
	test: Test_ACP
	test_acp_init(&test, .Always_Ask)
	defer test_acp_destroy(&test)
	test_use_fake_safety_model(&test)
	test_initialize(&test)
	sessionID := test_new_session(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	session.fake_provider_add_delayed_response(
		&test.provider,
		300 * time.Millisecond,
		session.fake_provider_text_line("SAFE|Prints the working directory.", true),
	)
	test_queue_text(&test, "ok")

	id := test_prompt(&test, sessionID, "run")
	// Under Always_Ask the request is sent at once; the classifier is only advice.
	request, requestIndex := test_wait_method(&test, "session/request_permission")
	params, _ := json_get_object(request, "params")
	toolCall, _ := json_get_object(params, "toolCall")
	toolCallID, _ := json_get_string(toolCall, "toolCallId")
	assert(
		test_content_text(toolCall) == "Safety check: running.",
		"expected the running safety check in the request",
	)
	advice: json.Object
	start := time.tick_now()
	for advice == nil {
		test_tick(&test)
		for index := requestIndex + 1; index < len(test.lines); index += 1 {
			update, updateIndex := test_find_update(&test, "tool_call_update", index, toolCallID)
			if update == nil {
				break
			}
			index = updateIndex
			if strings.contains(test_content_text(update), "Safety check: safe.") {
				advice = update
			}
		}
		assert(time.tick_since(start) < TEST_TIMEOUT, "expected the verdict as an update")
		time.sleep(2 * time.Millisecond)
	}
	status, _ := json_get_string(advice, "status")
	assert(status == "pending", "expected the call to stay pending")
	assert(
		test_count_method(&test, "session/request_permission") == 1,
		"expected no second request",
	)
	test_select_option(&test, request, "allow-once")
	response, _ := test_wait_response(&test, id)
	assert(test_stop_reason(response) == "end_turn", "expected end_turn")
	_ = t
}
