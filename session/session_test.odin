package session

import "../agent"
import "../settings"
import "../tool_policy"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Tests of the session event interface. Each test runs a session against a Fake_Provider, so
// whole turns run without a real model.

TEST_EVENT_TIMEOUT :: 10 * time.Second

// Numbers the fake providers, so parallel tests register different AI interface names.
testProviderCounter: int

Test_Session :: struct {
	config:      settings.Mimir_Config,
	provider:    Fake_Provider,
	session:     ^Session,
	projectRoot: string,
	// The events drained from the session, owned by the test.
	events:      [dynamic]Session_Event,
}

// Starts a fake provider and a session that uses it. The safety model is missing, so the
// safety classifier is unavailable unless a test selects the fake provider for it.
test_session_init :: proc(
	test: ^Test_Session,
	method: settings.Approval_Method,
	configHome := "",
) {
	counter := sync.atomic_add(&testProviderCounter, 1)
	name := fmt.tprintf("session-test-%d", counter)
	assert(fake_provider_start(&test.provider, name), "expected the fake provider to start")

	test.config = settings.default_ollama_config(context.allocator)
	clear(&test.config.providers)
	append(&test.config.providers, fake_provider_config(&test.provider))
	test.config.selectedProvider = test.provider.name
	test.config.selectedModel = FAKE_PROVIDER_MODEL
	test.config.approvalMethod = method
	test.config.safetyProvider = "session-test-missing-provider"
	test.config.safetyModel = "session-test-missing-model"

	projectRoot, projectErr := os.make_directory_temp("", "session-test-*", context.allocator)
	assert(projectErr == nil, "expected a temporary project root")
	test.projectRoot = projectRoot
	test.events = make([dynamic]Session_Event, 0, 32, context.allocator)

	sessionErr: Session_Error
	test.session, sessionErr = session_create(
		&test.config,
		session_options_from_config(&test.config, test.projectRoot, configHome),
	)
	assert(sessionErr == .None, "expected the session to be created")
}

test_session_destroy :: proc(test: ^Test_Session) {
	session_destroy(test.session)
	test.session = nil
	session_events_destroy(&test.events, context.allocator)
	fake_provider_stop(&test.provider)
	for &grant in test.config.permissionGrants {
		tool_policy.permission_grant_destroy(&grant, context.allocator)
	}
	delete(test.config.providers)
	delete(test.config.disabledSkills)
	delete(test.config.permissionGrants)
	delete(test.config.contextWindows)
	_ = os.remove_all(test.projectRoot)
	delete(test.projectRoot)
}

// Moves the pending events of the session into test.events.
test_session_drain :: proc(test: ^Test_Session) {
	for {
		event, ok := session_next_event(test.session)
		if !ok {
			return
		}
		append(&test.events, event)
	}
}

// Returns the first event of type T at or after index from, and its index.
test_find_event :: proc(test: ^Test_Session, $T: typeid, from := 0) -> (^T, int) {
	for index := from; index < len(test.events); index += 1 {
		if value, ok := &test.events[index].(T); ok {
			return value, index
		}
	}
	return nil, -1
}

test_count_events :: proc(test: ^Test_Session, $T: typeid) -> int {
	count := 0
	for &event in test.events {
		if _, ok := event.(T); ok {
			count += 1
		}
	}
	return count
}

// Polls the session until an event of type T arrives at or after index from.
test_wait_for_event :: proc(test: ^Test_Session, $T: typeid, from := 0) -> (^T, int) {
	start := time.tick_now()
	for {
		_ = session_poll(test.session)
		test_session_drain(test)
		if value, index := test_find_event(test, T, from); value != nil {
			return value, index
		}
		if time.tick_since(start) > TEST_EVENT_TIMEOUT {
			return nil, -1
		}
		time.sleep(2 * time.Millisecond)
	}
}

// Waits for the end of the turn.
test_wait_for_turn_end :: proc(test: ^Test_Session) -> ^Turn_Ended {
	ended, _ := test_wait_for_event(test, Turn_Ended)
	if ended == nil {
		// Show what happened instead.
		for event in test.events {
			fmt.eprintln(event)
		}
	}
	assert(ended != nil, "expected the turn to end")
	return ended
}

// Returns the streamed text of the main agent (depth 0) or of the subagents (depth 1 or more).
test_streamed_text :: proc(test: ^Test_Session, subagent: bool) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for &event in test.events {
		if delta, ok := event.(Message_Delta); ok && (delta.subagentDepth > 0) == subagent {
			strings.write_string(&builder, delta.text)
		}
	}
	return strings.to_string(builder)
}

// Returns the statuses of the Tool_Call_Updated events of toolCallID, in order.
test_tool_statuses :: proc(test: ^Test_Session, toolCallID: string) -> []Tool_Call_Status {
	statuses := make([dynamic]Tool_Call_Status, 0, 4, context.temp_allocator)
	for &event in test.events {
		if update, ok := event.(Tool_Call_Updated); ok && update.toolCallID == toolCallID {
			append(&statuses, update.status)
		}
	}
	return statuses[:]
}

test_statuses_equal :: proc(actual: []Tool_Call_Status, expected: ..Tool_Call_Status) -> bool {
	if len(actual) != len(expected) {
		return false
	}
	for status, index in actual {
		if status != expected[index] {
			return false
		}
	}
	return true
}

// Queues a response with one tool call and then a response with the final text.
test_queue_tool_turn :: proc(test: ^Test_Session, toolName, argumentsJSON: string) {
	fake_provider_add_response(
		&test.provider,
		false,
		fake_provider_tool_call_line(toolName, argumentsJSON),
		fake_provider_text_line("", true),
	)
}

PWD_ARGUMENTS :: `{"command":"pwd"}`
FIRST_TOOL_CALL_ID :: "ollama-0"

@(test)
test_session_submit_streams_text_and_ends_turn :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	fake_provider_add_response(
		&test.provider,
		false,
		fake_provider_text_line("Hello "),
		fake_provider_text_line("world"),
		fake_provider_text_line("", true),
	)

	assert(session_submit(test.session, "hi") == .None, "expected the turn to start")
	assert(session_turn_active(test.session), "expected an active turn after submit")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	assert(test_streamed_text(&test, false) == "Hello world", "expected the streamed text")
	assert(!session_turn_active(test.session), "expected no active turn after the end")

	firstUsage, firstUsageIndex := test_find_event(&test, Usage_Updated)
	assert(firstUsage != nil, "expected a usage event when the turn starts")
	assert(!firstUsage.usage.hasInputTokens, "expected empty usage when the turn starts")
	lastUsage, _ := test_find_event(&test, Usage_Updated, firstUsageIndex + 1)
	assert(
		lastUsage != nil && lastUsage.usage.inputTokens == 12,
		"expected the reported input tokens as the context usage",
	)

	transcript := &test.session.transcript
	assert(len(transcript.entries) == 2, "expected the user and assistant text in the transcript")
	assert(transcript.entries[0].content == "hi", "expected the user text first")
	assert(transcript.entries[1].content == "Hello world", "expected the assistant text")
	_ = t
}

@(test)
test_session_submit_returns_busy_during_a_turn_and_cancel_ends_it :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	fake_provider_add_response(&test.provider, true, fake_provider_text_line("partial"))

	assert(session_submit(test.session, "first") == .None, "expected the turn to start")
	assert(session_submit(test.session, "second") == .Busy, "expected .Busy during a turn")
	delta, _ := test_wait_for_event(&test, Message_Delta)
	assert(delta != nil && delta.text == "partial", "expected the first streamed text")

	assert(session_cancel(test.session) == .None, "expected cancel to stop the turn")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Canceled, "expected a canceled turn")
	notice, _ := test_find_event(&test, Notice)
	assert(
		notice != nil && notice.text == "Canceling assistant stream",
		"expected the cancel notice",
	)
	assert(session_cancel(test.session) == .Not_Active, "expected no turn to cancel")
	assert(
		len(test.session.transcript.entries) >= 1 &&
		test.session.transcript.entries[0].content == "first",
		"expected the busy submit not to reach the transcript",
	)
	_ = t
}

@(test)
test_session_failed_turn_reports_error :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	// A response that is not Ollama JSON makes the stream fail.
	fake_provider_add_response(&test.provider, false, "not json")

	assert(session_submit(test.session, "hi") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Failed, "expected a failed turn")
	assert(ended.errorText != "", "expected the error text of the failed turn")
	transcript := &test.session.transcript
	assert(
		len(transcript.entries) == 2 && transcript.entries[1].content == ended.errorText,
		"expected the error text as an assistant message in the transcript",
	)
	_ = t
}

@(test)
test_session_submit_without_provider_fails_with_notice :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	session_set_model(test.session, "", "")

	assert(session_submit(test.session, "hi") == .Start_Failed, "expected the start to fail")
	test_session_drain(&test)
	notice, _ := test_find_event(&test, Notice)
	assert(notice != nil && notice.text == "No provider selected", "expected the reason")
	assert(!session_turn_active(test.session), "expected no active turn")
	_ = t
}

@(test)
test_session_create_requires_usable_model_when_asked :: proc(t: ^testing.T) {
	config := settings.default_ollama_config(context.allocator)
	defer {
		delete(config.providers)
		delete(config.disabledSkills)
		delete(config.permissionGrants)
		delete(config.contextWindows)
	}
	options := session_options_from_config(&config, "", "")
	options.requireUsableModel = true
	created, createErr := session_create(&config, options)
	assert(created == nil && createErr == .No_Usable_Model, "expected .No_Usable_Model")

	options.model = "some-model"
	created, createErr = session_create(&config, options)
	assert(created != nil && createErr == .None, "expected a session with a usable model")
	session_destroy(created)
	_ = t
}

@(test)
test_session_reports_allowed_tool_call_start_and_updates :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "find_code", `{"query":"needle"}`)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("Done", true))

	assert(session_submit(test.session, "find it") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")

	started, startedIndex := test_find_event(&test, Tool_Call_Started)
	assert(started != nil, "expected a tool call start")
	assert(started.toolCallID == FIRST_TOOL_CALL_ID, "expected the model's tool call ID")
	assert(started.toolID == "find_code", "expected the tool ID")
	assert(started.target == "needle", "expected the query as the target")
	assert(strings.contains(started.arguments, "needle"), "expected the raw arguments")
	_, updateIndex := test_find_event(&test, Tool_Call_Updated)
	assert(updateIndex > startedIndex, "expected the start before the first update")
	assert(
		test_statuses_equal(test_tool_statuses(&test, FIRST_TOOL_CALL_ID), .Running, .Completed),
		"expected running and completed updates",
	)
	assert(test_count_events(&test, Approval_Requested) == 0, "expected no approval request")
	assert(test_streamed_text(&test, false) == "Done", "expected the continuation text")
	_ = t
}

@(test)
test_session_rejects_invalid_tool_arguments :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	// patch_file needs patch_content, so these arguments are invalid.
	test_queue_tool_turn(&test, "patch_file", `{"file_path":"notes.md"}`)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the agent to resume after the rejection")
	started, _ := test_find_event(&test, Tool_Call_Started)
	assert(started != nil && started.target == "", "expected a start without a target")
	assert(
		test_statuses_equal(test_tool_statuses(&test, FIRST_TOOL_CALL_ID), .Failed),
		"expected the invalid call to fail",
	)
	_ = t
}

@(test)
test_session_approve_all_settles_without_approval_request :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	assert(test_count_events(&test, Approval_Requested) == 0, "expected no approval request")
	assert(test_count_events(&test, Approval_Resolved) == 0, "expected no approval resolution")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Running,
			.Completed,
		),
		"expected Approve_All to run the tool",
	)
	_ = t
}

@(test)
test_session_deny_all_settles_without_approval_request :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Deny_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the agent to resume after the denial")
	assert(test_count_events(&test, Approval_Requested) == 0, "expected no approval request")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Denied,
		),
		"expected Deny_All to deny the tool",
	)
	_ = t
}

// Runs a turn that requests pwd under Always_Ask and returns the approval request.
test_request_pwd_approval :: proc(test: ^Test_Session) -> ^Approval_Requested {
	test_queue_tool_turn(test, "run_in_terminal", PWD_ARGUMENTS)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))
	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	requested, requestedIndex := test_wait_for_event(test, Approval_Requested)
	assert(requested != nil, "expected an approval request")
	_, startedIndex := test_find_event(test, Tool_Call_Started)
	assert(
		startedIndex >= 0 && startedIndex < requestedIndex,
		"expected the tool call start before the approval request",
	)
	return requested
}

@(test)
test_session_always_ask_requests_approval_and_allow_once_runs_tool :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	requested := test_request_pwd_approval(&test)
	assert(requested.toolCallID == FIRST_TOOL_CALL_ID, "expected the tool call ID")
	assert(requested.action.effect == .Execute, "expected the permission action")
	assert(requested.action.command == "pwd", "expected the command of the action")
	assert(
		requested.safety.status == .Unavailable,
		"expected unavailable safety advice without a safety model",
	)

	assert(
		session_resolve_approval(test.session, "call-other", .Allow_Once) == .Unknown_Tool_Call,
		"expected an unknown tool call ID to be rejected",
	)
	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Allow_Once) == .None,
		"expected Allow_Once to resolve the approval",
	)
	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Deny) ==
		.No_Pending_Approval,
		"expected no pending approval after the resolution",
	)
	resolved, _ := test_wait_for_event(&test, Approval_Resolved)
	assert(resolved != nil && resolved.choice == .Allow_Once, "expected the resolved choice")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Running,
			.Completed,
		),
		"expected the approved tool to run",
	)
	call := tool_policy.Tool_Call {
		id      = "run_in_terminal",
		command = "pwd",
	}
	assert(
		tool_policy.tool_dispatch_decide(&test.session.dispatcher, call) == .Approval_Required,
		"expected Allow_Once not to add a grant",
	)
	_ = t
}

@(test)
test_session_deny_choice_resumes_agent :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	_ = test_request_pwd_approval(&test)

	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Deny) == .None,
		"expected Deny to resolve the approval",
	)
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the agent to resume after the denial")
	resolved, _ := test_find_event(&test, Approval_Resolved)
	assert(resolved != nil && resolved.choice == .Deny, "expected the denial")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Denied,
		),
		"expected the denied tool not to run",
	)
	_ = t
}

@(test)
test_session_allow_session_adds_session_grant :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	_ = test_request_pwd_approval(&test)

	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Allow_Session) == .None,
		"expected Allow_Session to resolve the approval",
	)
	_ = test_wait_for_turn_end(&test)
	call := tool_policy.Tool_Call {
		id      = "run_in_terminal",
		command = "pwd",
	}
	assert(
		tool_policy.tool_dispatch_decide(&test.session.dispatcher, call) == .Allowed_Session,
		"expected Allow_Session to add a session grant",
	)
	assert(len(test.config.permissionGrants) == 0, "expected no config grant")
	_ = t
}

@(test)
test_session_allow_always_appends_config_grant :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	_ = test_request_pwd_approval(&test)

	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Allow_Always) == .None,
		"expected Allow_Always to resolve the approval",
	)
	_ = test_wait_for_turn_end(&test)
	assert(len(test.config.permissionGrants) == 1, "expected one config grant")
	assert(test.config.permissionGrants[0].command == "pwd", "expected the approved command")
	call := tool_policy.Tool_Call {
		id      = "run_in_terminal",
		command = "pwd",
	}
	assert(
		tool_policy.tool_dispatch_decide(&test.session.dispatcher, call) == .Allowed_Persistent,
		"expected the dispatcher to read the config grant",
	)
	_ = t
}

@(test)
test_session_allow_always_keeps_approval_when_save_fails :: proc(t: ^testing.T) {
	home, homeErr := os.make_directory_temp("", "session-test-home-*", context.allocator)
	assert(homeErr == nil, "expected a temporary config home")
	defer {
		_ = os.remove_all(home)
		delete(home)
	}
	// A regular file where the config directory should be makes the save fail.
	blocker := strings.concatenate({home, "/.config"}, context.temp_allocator)
	assert(os.write_entire_file(blocker, "") == nil, "expected a config directory blocker")

	test: Test_Session
	test_session_init(&test, .Always_Ask, home)
	defer test_session_destroy(&test)
	_ = test_request_pwd_approval(&test)

	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Allow_Always) ==
		.Approval_Not_Applied,
		"expected a failed save to keep the approval pending",
	)
	assert(len(test.config.permissionGrants) == 0, "expected the grant to be rolled back")
	test_session_drain(&test)
	assert(test_count_events(&test, Approval_Resolved) == 0, "expected no resolution")
	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Deny) == .None,
		"expected the approval to stay pending",
	)
	_ = test_wait_for_turn_end(&test)
	_ = t
}

@(test)
test_session_cancel_settles_pending_approval :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	_ = test_request_pwd_approval(&test)

	assert(session_cancel(test.session) == .None, "expected cancel to stop the turn")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Canceled, "expected a canceled turn")
	resolved, _ := test_find_event(&test, Approval_Resolved)
	assert(resolved != nil && resolved.choice == .Deny, "expected cancel to deny the approval")
	// The denied tool call must not start a continuation that ends the turn a second time.
	for _ in 0 ..< 50 {
		_ = session_poll(test.session)
		time.sleep(2 * time.Millisecond)
	}
	test_session_drain(&test)
	assert(test_count_events(&test, Turn_Ended) == 1, "expected exactly one turn end")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Denied,
		),
		"expected the canceled approval to be denied",
	)
	_ = t
}

// Selects the fake provider as the safety model, with response as the classifier answer.
test_queue_safety_turn :: proc(test: ^Test_Session, safetyResponse: string) {
	test.config.safetyProvider = test.provider.name
	test.config.safetyModel = FAKE_PROVIDER_MODEL
	test_queue_tool_turn(test, "run_in_terminal", PWD_ARGUMENTS)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line(safetyResponse, true))
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))
}

@(test)
test_session_approve_safe_approves_safe_verdict :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_Safe)
	defer test_session_destroy(&test)
	test_queue_safety_turn(&test, "SAFE|Prints the working directory.")

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	requested, requestedIndex := test_find_event(&test, Approval_Requested)
	assert(requested != nil, "expected an approval request under Approve_Safe")
	assert(requested.safety.status == .Checking, "expected the classifier to run")
	updated, updatedIndex := test_find_event(&test, Approval_Safety_Updated)
	assert(updated != nil && updatedIndex > requestedIndex, "expected a safety update")
	assert(updated.safety.status == .Checked, "expected a finished classifier")
	assert(updated.safety.verdict == .Safe, "expected the safe verdict")
	assert(
		strings.has_prefix(updated.safety.response, "SAFE|"),
		"expected the classifier response",
	)
	resolved, resolvedIndex := test_find_event(&test, Approval_Resolved)
	assert(resolved != nil && resolvedIndex > updatedIndex, "expected an automatic approval")
	assert(resolved.choice == .Allow_Once, "expected a one-time approval")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, FIRST_TOOL_CALL_ID),
			.Awaiting_Approval,
			.Running,
			.Completed,
		),
		"expected the safe tool to run",
	)
	_ = t
}

@(test)
test_session_approve_safe_waits_for_choice_on_risky_verdict :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_Safe)
	defer test_session_destroy(&test)
	test_queue_safety_turn(&test, "RISKY|Could do anything.")

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	updated, _ := test_wait_for_event(&test, Approval_Safety_Updated)
	assert(updated != nil && updated.safety.verdict == .Risky, "expected the risky verdict")
	assert(test_count_events(&test, Approval_Resolved) == 0, "expected no automatic approval")
	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Deny) == .None,
		"expected the approval to wait for a choice",
	)
	_ = test_wait_for_turn_end(&test)
	_ = t
}

@(test)
test_session_approve_safe_asks_when_safety_is_unavailable :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_Safe)
	defer test_session_destroy(&test)
	requested := test_request_pwd_approval(&test)
	assert(requested.safety.status == .Unavailable, "expected unavailable safety advice")
	test_session_drain(&test)
	assert(test_count_events(&test, Approval_Resolved) == 0, "expected no automatic approval")
	assert(
		session_resolve_approval(test.session, FIRST_TOOL_CALL_ID, .Deny) == .None,
		"expected the approval to wait for a choice",
	)
	_ = test_wait_for_turn_end(&test)
	_ = t
}

@(test)
test_session_runs_subagent_and_resumes_parent :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Count files","tools":["find_code"]}`)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("child answer", true))
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("parent done", true))

	assert(session_submit(test.session, "delegate") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")

	started, startedIndex := test_find_event(&test, Subagent_Started)
	assert(started != nil, "expected the subagent to start")
	assert(started.parentToolCallID == FIRST_TOOL_CALL_ID, "expected the parent tool call")
	assert(started.task == "Count files", "expected the subagent task")
	childDelta, childIndex := test_find_event(&test, Message_Delta, startedIndex)
	assert(childDelta != nil && childDelta.subagentDepth == 1, "expected subagent text")
	assert(
		childDelta.parentToolCallID == FIRST_TOOL_CALL_ID,
		"expected the subagent text to name its run_subagent call",
	)
	finished, finishedIndex := test_find_event(&test, Subagent_Finished)
	assert(finished != nil && finishedIndex > childIndex, "expected the subagent to finish")
	assert(!finished.failed, "expected a successful subagent")
	assert(finished.result == "child answer", "expected the subagent result")
	assert(test_streamed_text(&test, true) == "child answer", "expected the subagent text")
	assert(test_streamed_text(&test, false) == "parent done", "expected the parent text")

	transcript := &test.session.transcript
	for entry in transcript.entries {
		assert(entry.content != "child answer", "expected subagent text outside the transcript")
	}
	_ = t
}

@(test)
test_session_queued_tool_call_waits_for_the_first :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	fake_provider_add_response(
		&test.provider,
		false,
		fake_provider_tool_call_line("run_in_terminal", PWD_ARGUMENTS),
		fake_provider_tool_call_line("run_in_terminal", `{"command":"ls"}`),
		fake_provider_text_line("", true),
	)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	first, firstIndex := test_wait_for_event(&test, Approval_Requested)
	assert(first != nil && first.toolCallID == "ollama-0", "expected the first tool call")
	assert(
		session_resolve_approval(test.session, "ollama-0", .Allow_Once) == .None,
		"expected the first approval to resolve",
	)
	second, _ := test_wait_for_event(&test, Approval_Requested, firstIndex + 1)
	assert(second != nil && second.toolCallID == "ollama-1", "expected the queued tool call")
	assert(second.action.command == "ls", "expected the command of the queued call")
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, "ollama-0"),
			.Awaiting_Approval,
			.Running,
			.Completed,
		),
		"expected the first tool to finish before the second request",
	)
	assert(
		session_resolve_approval(test.session, "ollama-1", .Deny) == .None,
		"expected the second approval to resolve",
	)
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	_ = t
}

@(test)
test_session_transcript_splits_assistant_text_around_tools :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	fake_provider_add_response(
		&test.provider,
		false,
		fake_provider_text_line("I will check."),
		fake_provider_tool_call_line("run_in_terminal", PWD_ARGUMENTS),
		fake_provider_text_line("", true),
	)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("Clean.", true))

	assert(session_submit(test.session, "check") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	entries := test.session.transcript.entries[:]
	assert(len(entries) == 3, "expected the user text and two assistant messages")
	assert(entries[1].content == "I will check.", "expected the text before the tool")
	assert(entries[2].content == "Clean.", "expected the continuation as a new message")
	_ = t
}

@(test)
test_session_destroy_frees_events_during_a_turn :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	fake_provider_add_response(&test.provider, true, fake_provider_text_line("partial"))

	assert(session_submit(test.session, "hi") == .None, "expected the turn to start")
	delta, _ := test_wait_for_event(&test, Message_Delta)
	assert(delta != nil, "expected streamed text")
	// The session still holds undrained events and an active stream. Destroying it must free
	// both; the tracking allocator of the test reports any leak.
	session_emit_notice(test.session, "left in the queue")
	session_destroy(test.session)
	test.session = nil
	_ = t
}

@(test)
test_session_event_destroy_frees_every_event_type :: proc(t: ^testing.T) {
	allocator := context.allocator
	action := tool_policy.Permission_Action {
		effect           = .Execute,
		projectRoot      = "/project",
		command          = "pwd",
		workingDirectory = "/project",
	}
	safety := Approval_Safety {
		status   = .Checked,
		verdict  = .Safe,
		response = "SAFE|ok",
	}
	events := []Session_Event {
		Message_Delta {
			text = strings.clone("text", allocator),
			parentToolCallID = strings.clone("call", allocator),
		},
		Thinking_Changed{thinking = true},
		Usage_Updated{contextWindowTokens = 10},
		Tool_Call_Started {
			toolCallID = strings.clone("call", allocator),
			toolID = strings.clone("tool", allocator),
			target = strings.clone("target", allocator),
			arguments = strings.clone("{}", allocator),
		},
		Tool_Call_Updated {
			toolCallID = strings.clone("call", allocator),
			output = strings.clone("output", allocator),
			diff = file_diff_copy(
				File_Diff{path = "/project/a.txt", oldText = "old", newText = "new"},
				allocator,
			),
		},
		Approval_Requested {
			toolCallID = strings.clone("call", allocator),
			action = permission_action_copy(action, allocator),
			safety = approval_safety_copy(safety, allocator),
		},
		Approval_Safety_Updated {
			toolCallID = strings.clone("call", allocator),
			safety = approval_safety_copy(safety, allocator),
		},
		Approval_Resolved{toolCallID = strings.clone("call", allocator)},
		Subagent_Started {
			parentToolCallID = strings.clone("call", allocator),
			task = strings.clone("task", allocator),
		},
		Subagent_Finished {
			parentToolCallID = strings.clone("call", allocator),
			task = strings.clone("task", allocator),
			result = strings.clone("result", allocator),
			errorText = strings.clone("error", allocator),
		},
		Turn_Ended{errorText = strings.clone("error", allocator)},
		Notice{text = strings.clone("notice", allocator)},
	}
	for &event in events {
		session_event_destroy(&event, allocator)
		assert(event == nil, "expected a destroyed event to be cleared")
	}
	_ = t
}

@(test)
test_session_defers_skill_settings_while_a_tool_runs :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	test.session.toolExecution.active = true
	session_apply_skill_settings(test.session)
	assert(test.session.skillSettingsPending, "expected the skill change to wait for the tool")
	session_rebuild_code_index(test.session)
	assert(test.session.codeIndexRebuildPending, "expected the rebuild to wait for the tool")
	test.session.toolExecution.active = false
	session_apply_skill_settings(test.session)
	assert(!test.session.skillSettingsPending, "expected the skill change without a tool")
	_ = t
}

@(test)
test_agent_host_starts_active_and_background_agents :: proc(t: ^testing.T) {
	host := agent_host_init(context.allocator)
	defer agent_host_destroy(&host)

	assert(
		agent_host_start_active(&host, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	activeState, activeOK := agent.runtime_state(&host.runtime, host.activeAgentID)
	assert(activeOK && activeState == .Streaming, "expected active agent to be streaming")
	backgroundID, backgroundErr := agent_host_start_background(&host, agent.Agent_Start_Options{})
	assert(backgroundErr == .None, "expected background agent to start")
	backgroundState, backgroundOK := agent.runtime_state(&host.runtime, backgroundID)
	assert(backgroundOK && backgroundState == .Idle, "expected idle background agent")
	_ = t
}

@(test)
test_session_makes_repeated_model_tool_call_ids_unique :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	// Ollama numbers the tool calls of each response from ollama-0, so both responses use the
	// same model ID.
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	test_queue_tool_turn(&test, "run_in_terminal", `{"command":"ls"}`)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "run") == .None, "expected the turn to start")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the turn to complete")
	first, firstIndex := test_find_event(&test, Tool_Call_Started)
	second, _ := test_find_event(&test, Tool_Call_Started, firstIndex + 1)
	assert(first != nil && second != nil, "expected two tool calls")
	assert(first.toolCallID == FIRST_TOOL_CALL_ID, "expected the model ID for a new ID")
	assert(
		second.toolCallID == "ollama-0-2",
		fmt.tprintf("expected a unique ID for the repeated model ID, got %q", second.toolCallID),
	)
	assert(
		test_statuses_equal(
			test_tool_statuses(&test, "ollama-0-2"),
			.Awaiting_Approval,
			.Running,
			.Completed,
		),
		"expected the updates of the second call to use its unique ID",
	)

	// A later turn keeps the IDs unique.
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))
	eventCount := len(test.events)
	assert(session_submit(test.session, "again") == .None, "expected the second turn to start")
	_, _ = test_wait_for_event(&test, Turn_Ended, eventCount)
	third, _ := test_find_event(&test, Tool_Call_Started, eventCount)
	assert(third != nil && third.toolCallID == "ollama-0-3", "expected a unique ID in turn two")
	_ = t
}

@(test)
test_session_unique_tool_call_id_skips_taken_suffixes :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	assert(session_unique_tool_call_id(test.session, "a-2") == "a-2", "expected a new ID")
	assert(session_unique_tool_call_id(test.session, "a") == "a", "expected a new ID")
	assert(session_unique_tool_call_id(test.session, "a") == "a-3", "expected a free suffix")
	assert(session_unique_tool_call_id(test.session, "") == "call", "expected a default ID")
	_ = t
}

// Polls the session for a while and keeps the events, so a test can check that nothing more
// happens.
test_session_settle :: proc(test: ^Test_Session) {
	for _ in 0 ..< 50 {
		_ = session_poll(test.session)
		time.sleep(2 * time.Millisecond)
	}
	test_session_drain(test)
}

@(test)
test_session_cancel_turn_ends_the_turn_during_a_subagent :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Wait","tools":["find_code"]}`)
	// The subagent streams text and then waits until it is canceled.
	fake_provider_add_response(&test.provider, true, fake_provider_text_line("child working"))

	assert(session_submit(test.session, "delegate") == .None, "expected the turn to start")
	delta, _ := test_wait_for_event(&test, Message_Delta)
	assert(delta != nil && delta.subagentDepth == 1, "expected the subagent to stream")

	assert(session_cancel_turn(test.session) == .None, "expected the turn to be canceled")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Canceled, "expected a canceled turn")
	finished, finishedIndex := test_find_event(&test, Subagent_Finished)
	_, endedIndex := test_find_event(&test, Turn_Ended)
	assert(finished != nil && finished.failed, "expected the subagent to finish as failed")
	assert(finishedIndex < endedIndex, "expected the subagent to finish before the turn ends")
	test_session_settle(&test)
	assert(test_count_events(&test, Turn_Ended) == 1, "expected exactly one turn end")
	assert(!session_turn_active(test.session), "expected no active turn")
	assert(session_cancel_turn(test.session) == .Not_Active, "expected no turn to cancel")
	_ = t
}

@(test)
test_session_cancel_turn_denies_a_subagent_approval :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Always_Ask)
	defer test_session_destroy(&test)
	// run_subagent itself needs no approval. The subagent then asks to run pwd.
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Run","tools":["run_in_terminal"]}`)
	test_queue_tool_turn(&test, "run_in_terminal", PWD_ARGUMENTS)

	assert(session_submit(test.session, "delegate") == .None, "expected the turn to start")
	requested, _ := test_wait_for_event(&test, Approval_Requested)
	assert(requested != nil, "expected the subagent's tool call to wait for approval")

	assert(session_cancel_turn(test.session) == .None, "expected the turn to be canceled")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Canceled, "expected a canceled turn")
	resolved, _ := test_find_event(&test, Approval_Resolved)
	assert(
		resolved != nil && resolved.toolCallID == requested.toolCallID && resolved.choice == .Deny,
		"expected cancel to deny the pending approval",
	)
	test_session_settle(&test)
	assert(test_count_events(&test, Turn_Ended) == 1, "expected exactly one turn end")
	assert(!pending_approval_active(&test.session.approval), "expected no pending approval")
	_ = t
}

@(test)
test_session_cancel_during_a_subagent_cancels_only_the_subagent :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(&test, "run_subagent", `{"task":"Wait","tools":["find_code"]}`)
	fake_provider_add_response(&test.provider, true, fake_provider_text_line("child working"))
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("parent done", true))

	assert(session_submit(test.session, "delegate") == .None, "expected the turn to start")
	delta, _ := test_wait_for_event(&test, Message_Delta)
	assert(delta != nil && delta.subagentDepth == 1, "expected the subagent to stream")

	// The terminal /stop keeps its behavior: the parent gets the failed result and goes on.
	assert(session_cancel(test.session) == .None, "expected the subagent to be canceled")
	ended := test_wait_for_turn_end(&test)
	assert(ended.reason == .Completed, "expected the parent to complete the turn")
	assert(test_streamed_text(&test, false) == "parent done", "expected the parent text")
	_ = t
}

// Returns the last Tool_Call_Updated event of toolCallID.
test_last_tool_update :: proc(test: ^Test_Session, toolCallID: string) -> ^Tool_Call_Updated {
	for index := len(test.events) - 1; index >= 0; index -= 1 {
		if update, ok := &test.events[index].(Tool_Call_Updated); ok &&
		   update.toolCallID == toolCallID {
			return update
		}
	}
	return nil
}

@(test)
test_session_write_file_update_carries_a_new_file_diff :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	test_queue_tool_turn(
		&test,
		"write_file",
		`{"file_path":"notes.md","content":"hello\n","overwrite":"false"}`,
	)
	test_queue_tool_turn(
		&test,
		"write_file",
		`{"file_path":"notes.md","content":"again\n","overwrite":"false"}`,
	)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "write") == .None, "expected the turn to start")
	_ = test_wait_for_turn_end(&test)
	update := test_last_tool_update(&test, FIRST_TOOL_CALL_ID)
	assert(update != nil && update.status == .Completed, "expected the write to complete")
	expectedPath := strings.concatenate({test.projectRoot, "/notes.md"}, context.temp_allocator)
	assert(
		update.diff.path == expectedPath,
		fmt.tprintf("expected the absolute path %q, got %q", expectedPath, update.diff.path),
	)
	assert(update.diff.newFile && update.diff.oldText == "", "expected a new file")
	assert(update.diff.newText == "hello\n", "expected the whole new text")

	// The second write fails because the file exists, so it has no diff.
	failed := test_last_tool_update(&test, "ollama-0-2")
	assert(failed != nil && failed.status == .Failed, "expected the second write to fail")
	assert(failed.diff.path == "", "expected no diff for a failed write")
	_ = t
}

@(test)
test_session_patch_file_update_carries_old_and_new_text :: proc(t: ^testing.T) {
	test: Test_Session
	test_session_init(&test, .Approve_All)
	defer test_session_destroy(&test)
	path := strings.concatenate({test.projectRoot, "/main.txt"}, context.temp_allocator)
	assert(os.write_entire_file(path, "one\ntwo\n") == nil, "expected the test file")
	test_queue_tool_turn(
		&test,
		"patch_file",
		`{"file_path":"main.txt","patch_content":"--- a/main.txt\n+++ b/main.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+three\n"}`,
	)
	fake_provider_add_response(&test.provider, false, fake_provider_text_line("ok", true))

	assert(session_submit(test.session, "patch") == .None, "expected the turn to start")
	_ = test_wait_for_turn_end(&test)
	update := test_last_tool_update(&test, FIRST_TOOL_CALL_ID)
	assert(
		update != nil && update.status == .Completed,
		fmt.tprintf("expected the patch to complete, got %v", update^),
	)
	assert(update.diff.path == path, "expected the absolute path")
	assert(!update.diff.newFile, "expected an existing file")
	assert(update.diff.oldText == "one\ntwo\n", "expected the whole old text")
	assert(update.diff.newText == "one\nthree\n", "expected the whole new text")
	_ = t
}
