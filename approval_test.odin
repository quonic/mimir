#+vet explicit-allocators
package main

import "agent"
import "approval_safety"
import "core:testing"
import "settings"
import "tool_policy"

APPROVAL_TEST_REQUEST_ID :: "call-1"

// approval_test_init returns an app whose safety classifier is always
// unavailable, so no test contacts a model provider.
approval_test_init :: proc(method: settings.Approval_Method) -> App_State {
	state := app_init(context.allocator)
	state.config.approvalMethod = method
	state.config.safetyProvider = "approval-test-missing-provider"
	state.config.safetyModel = "approval-test-missing-model"
	return state
}

// approval_test_start_request starts the active agent and makes it request a
// run_in_terminal call, so the approval has a runtime request to resolve.
approval_test_start_request :: proc(state: ^App_State) -> agent.Agent_ID {
	assert(
		agent_host_start_active(&state.agentHost, agent.Agent_Start_Options{}) == .None,
		"expected active agent to start",
	)
	agentID := state.agentHost.activeAgentID
	assert(
		agent.runtime_request_tool(
			&state.agentHost.runtime,
			agentID,
			agent.Tool_Request {
				id = APPROVAL_TEST_REQUEST_ID,
				name = "run_in_terminal",
				arguments = `{"command":"pwd"}`,
			},
		) ==
		.None,
		"expected runtime tool request",
	)
	requestEvent, requestEventOK := agent.runtime_next_event(&state.agentHost.runtime, agentID)
	assert(requestEventOK, "expected runtime tool request event")
	agent.agent_event_destroy(&requestEvent, context.allocator)
	return agentID
}

approval_test_call :: proc() -> tool_policy.Tool_Call {
	return tool_policy.Tool_Call{id = "run_in_terminal", command = "pwd"}
}

// approval_test_request asks for approval of the test call and checks that
// the decision logic did not open an overlay.
approval_test_request :: proc(
	state: ^App_State,
	agentID: agent.Agent_ID,
) -> Approval_Request_Result {
	result := app_request_approval(state, approval_test_call(), agentID, APPROVAL_TEST_REQUEST_ID)
	assert(
		len(state.overlayStack) == 0,
		"expected approval decision logic not to open an overlay",
	)
	return result
}

// approval_test_set_safety_response gives the pending approval a finished
// safety classifier with response, as if the classifier thread had returned it.
approval_test_set_safety_response :: proc(state: ^App_State, response: string) {
	approval_safety.init(&state.approval.safety, state.dispatcher.allocator)
	append(&state.approval.safety.response, response)
}

approval_test_last_history :: proc(state: ^App_State) -> string {
	assert(len(state.history) > 0, "expected a tool history entry")
	return state.history[len(state.history) - 1].content
}

approval_test_agent_state :: proc(state: ^App_State, agentID: agent.Agent_ID) -> agent.Agent_State {
	agentState, agentOK := agent.runtime_state(&state.agentHost.runtime, agentID)
	assert(agentOK, "expected agent runtime state")
	return agentState
}

// approval_test_finish_tool waits for the started tool to finish, so the test
// does not leave a running tool worker.
approval_test_finish_tool :: proc(state: ^App_State) {
	assert(state.toolExecution.active, "expected tool execution to be active")
	_ = app_poll_agent_host(state)
	for !app_poll_tool_execution(state) {
	}
}

// approval_test_destroy_grants frees the grants that Allow_Always added to the
// config. app_destroy does not free grant strings when the config strings are
// not owned.
approval_test_destroy_grants :: proc(state: ^App_State) {
	for &grant in state.config.permissionGrants {
		tool_policy.permission_grant_destroy(&grant, state.dispatcher.allocator)
	}
	clear(&state.config.permissionGrants)
}

@(test)
test_approval_method_approve_all_settles_without_overlay :: proc(t: ^testing.T) {
	state := approval_test_init(.Approve_All)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	result := approval_test_request(&state, agentID)
	assert(result == .Settled, "expected Approve_All to settle the call")
	assert(!app_approval_pending(&state), "expected no pending approval after Approve_All")
	assert(state.toolExecution.active, "expected Approve_All to start the tool")
	assert(
		approval_test_agent_state(&state, agentID) == .Executing_Tool,
		"expected Approve_All to leave the agent executing the tool",
	)
	assert(
		approval_test_last_history(&state) == "run_in_terminal: pwd (running)",
		"expected Approve_All tool history to show running",
	)
	approval_test_finish_tool(&state)
	_ = t
}

@(test)
test_approval_method_deny_all_settles_without_overlay :: proc(t: ^testing.T) {
	state := approval_test_init(.Deny_All)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	result := approval_test_request(&state, agentID)
	assert(result == .Settled, "expected Deny_All to settle the call")
	assert(!app_approval_pending(&state), "expected no pending approval after Deny_All")
	assert(!state.toolExecution.active, "expected Deny_All not to start the tool")
	assert(state.status == "Tool call denied", "expected Deny_All denial status")
	assert(
		approval_test_agent_state(&state, agentID) == .Streaming,
		"expected Deny_All to resume the agent",
	)
	assert(
		approval_test_last_history(&state) == "run_in_terminal: pwd (denied)",
		"expected Deny_All tool history to show denied",
	)
	_ = t
}

@(test)
test_approval_method_always_ask_waits_for_choice :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	result := approval_test_request(&state, agentID)
	assert(result == .Awaiting_Choice, "expected Always_Ask to wait for a choice")
	assert(app_approval_pending(&state), "expected a pending approval")
	assert(!app_apply_approval_method(&state), "expected Always_Ask not to choose")
	assert(!state.toolExecution.active, "expected Always_Ask not to start the tool")
	assert(
		approval_test_last_history(&state) == "run_in_terminal: pwd (awaiting approval)",
		"expected Always_Ask tool history to show awaiting approval",
	)

	app_sync_approval_overlay(&state)
	assert(app_has_overlay(&state, Approval_Overlay), "expected the overlay to show the prompt")
	assert(state.approvalView.choice == .Allow_Once, "expected Allow_Once selected initially")
	assert(state.status == "Permission approval required", "expected prompt status")
	app_sync_approval_overlay(&state)
	assert(len(state.overlayStack) == 1, "expected a second sync not to push another overlay")

	app_apply_approval_choice(&state, .Deny)
	assert(len(state.overlayStack) == 0, "expected the overlay to hide after the choice")
	_ = t
}

@(test)
test_approval_method_approve_safe_approves_safe_verdict :: proc(t: ^testing.T) {
	state := approval_test_init(.Approve_Safe)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	result := approval_test_request(&state, agentID)
	assert(result == .Awaiting_Choice, "expected Approve_Safe to wait for a verdict")
	approval_test_set_safety_response(&state, "SAFE|Prints the working directory.")
	assert(app_apply_approval_method(&state), "expected a safe verdict to approve the call")
	assert(len(state.overlayStack) == 0, "expected a safe verdict not to open an overlay")
	assert(!app_approval_pending(&state), "expected no pending approval after a safe verdict")
	assert(state.toolExecution.active, "expected a safe verdict to start the tool")
	assert(
		approval_test_agent_state(&state, agentID) == .Executing_Tool,
		"expected a safe verdict to leave the agent executing the tool",
	)
	approval_test_finish_tool(&state)
	_ = t
}

@(test)
test_approval_method_approve_safe_prompts_on_unsafe_verdict :: proc(t: ^testing.T) {
	state := approval_test_init(.Approve_Safe)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	assert(
		approval_test_request(&state, agentID) == .Awaiting_Choice,
		"expected Approve_Safe to wait for a verdict",
	)
	unsafeResponses := []string{"RISKY|Changes files.", "UNCLEAR|Unknown effect.", "garbage"}
	for response in unsafeResponses {
		approval_test_set_safety_response(&state, response)
		assert(!app_apply_approval_method(&state), "expected an unsafe verdict not to choose")
		assert(app_approval_pending(&state), "expected an unsafe verdict to keep the call pending")
		assert(!state.toolExecution.active, "expected an unsafe verdict not to start the tool")
	}
	assert(len(state.overlayStack) == 0, "expected no overlay from the decision logic")
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny) == .Resolved,
		"expected the prompt to accept a denial",
	)
	_ = t
}

@(test)
test_approval_method_approve_safe_prompts_on_unavailable_verdict :: proc(t: ^testing.T) {
	state := approval_test_init(.Approve_Safe)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	assert(
		approval_test_request(&state, agentID) == .Awaiting_Choice,
		"expected unavailable safety advice to wait for a choice",
	)
	assert(
		pending_approval_safety_unavailable(&state.approval),
		"expected a missing safety provider to make safety advice unavailable",
	)
	assert(
		pending_approval_safety_ready(&state.approval),
		"expected unavailable advice to be ready",
	)
	assert(!app_apply_approval_method(&state), "expected unavailable advice not to choose")
	assert(app_approval_pending(&state), "expected unavailable advice to keep the call pending")
	assert(!state.toolExecution.active, "expected unavailable advice not to start the tool")
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny) == .Resolved,
		"expected the prompt to accept a denial",
	)
	_ = t
}

@(test)
test_approval_method_approve_safe_waits_while_classifier_runs :: proc(t: ^testing.T) {
	state := approval_test_init(.Approve_Safe)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)

	assert(
		approval_test_request(&state, agentID) == .Awaiting_Choice,
		"expected Approve_Safe to wait for a verdict",
	)
	approval_test_set_safety_response(&state, "SAFE|Prints the working directory.")
	state.approval.safety.active = true
	assert(!pending_approval_safety_ready(&state.approval), "expected a running classifier")
	assert(!app_apply_approval_method(&state), "expected a running classifier not to choose")
	assert(app_approval_pending(&state), "expected a running classifier to keep the call pending")
	assert(
		!app_poll_pending_approval(&state),
		"expected no poll result while the classifier has not finished",
	)
	state.approval.safety.active = false
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny) == .Resolved,
		"expected the prompt to accept a denial",
	)
	_ = t
}

@(test)
test_approval_resolve_allow_once_starts_tool_without_overlay :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")

	result := app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Allow_Once)
	assert(result == .Resolved, "expected Allow_Once to resolve the call")
	assert(len(state.overlayStack) == 0, "expected resolve not to touch overlays")
	assert(!app_approval_pending(&state), "expected no pending approval after Allow_Once")
	assert(state.toolExecution.active, "expected Allow_Once to start the tool")
	assert(
		approval_test_last_history(&state) == "run_in_terminal: pwd (running)",
		"expected Allow_Once tool history to show running",
	)
	assert(
		tool_policy.tool_dispatch_decide(&state.dispatcher, approval_test_call()) ==
		.Approval_Required,
		"expected Allow_Once not to add a grant",
	)
	approval_test_finish_tool(&state)
	assert(
		approval_test_agent_state(&state, agentID) == .Streaming,
		"expected the finished tool to resume the agent",
	)
	_ = t
}

@(test)
test_approval_resolve_allow_session_adds_dispatcher_grant :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")
	grantCount := len(state.config.permissionGrants)

	result := app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Allow_Session)
	assert(result == .Resolved, "expected Allow_Session to resolve the call")
	assert(len(state.overlayStack) == 0, "expected resolve not to touch overlays")
	assert(state.toolExecution.active, "expected Allow_Session to start the tool")
	assert(
		tool_policy.tool_dispatch_decide(&state.dispatcher, approval_test_call()) ==
		.Allowed_Session,
		"expected Allow_Session to add a dispatcher grant",
	)
	assert(
		len(state.config.permissionGrants) == grantCount,
		"expected Allow_Session not to change the config grants",
	)
	approval_test_finish_tool(&state)
	_ = t
}

@(test)
test_approval_resolve_allow_always_appends_config_grant :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	defer approval_test_destroy_grants(&state)
	assert(state.configHome == "", "expected tests not to save the config")
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")
	grantCount := len(state.config.permissionGrants)

	result := app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Allow_Always)
	assert(result == .Resolved, "expected Allow_Always to resolve the call")
	assert(len(state.overlayStack) == 0, "expected resolve not to touch overlays")
	assert(state.toolExecution.active, "expected Allow_Always to start the tool")
	assert(
		len(state.config.permissionGrants) == grantCount + 1,
		"expected Allow_Always to append one config grant",
	)
	grant := state.config.permissionGrants[len(state.config.permissionGrants) - 1]
	assert(grant.kind == .Command_Prefix, "expected a command prefix grant")
	assert(grant.command == "pwd", "expected the grant to hold the approved command")
	assert(
		tool_policy.tool_dispatch_decide(&state.dispatcher, approval_test_call()) ==
		.Allowed_Persistent,
		"expected the config grant to allow the call",
	)
	approval_test_finish_tool(&state)
	_ = t
}

@(test)
test_approval_resolve_deny_resolves_runtime_request :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")

	result := app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny)
	assert(result == .Resolved, "expected Deny to resolve the call")
	assert(len(state.overlayStack) == 0, "expected resolve not to touch overlays")
	assert(!app_approval_pending(&state), "expected no pending approval after Deny")
	assert(!state.toolExecution.active, "expected Deny not to start the tool")
	assert(state.status == "Tool call denied", "expected denial status")
	assert(
		approval_test_last_history(&state) == "run_in_terminal: pwd (denied)",
		"expected Deny tool history to show denied",
	)
	assert(
		approval_test_agent_state(&state, agentID) == .Streaming,
		"expected Deny to resume the agent",
	)
	_ = t
}

@(test)
test_approval_resolve_rejects_unknown_tool_call :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")

	result := app_resolve_approval(&state, "call-other", .Allow_Once)
	assert(result == .Unknown_Tool_Call, "expected an unknown tool call ID to be rejected")
	assert(app_approval_pending(&state), "expected the call to stay pending")
	assert(!state.toolExecution.active, "expected an unknown ID not to start the tool")
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny) == .Resolved,
		"expected the matching ID to resolve the call",
	)
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Allow_Once) ==
		.No_Pending_Approval,
		"expected a second resolve to find no pending approval",
	)
	_ = t
}

@(test)
test_approval_request_rejects_second_pending_call :: proc(t: ^testing.T) {
	state := approval_test_init(.Always_Ask)
	defer app_destroy(&state)
	agentID := approval_test_start_request(&state)
	assert(approval_test_request(&state, agentID) == .Awaiting_Choice, "expected a prompt")

	second := app_request_approval(&state, approval_test_call(), agentID, "call-2")
	assert(second == .Rejected, "expected a second approval to be rejected while one is pending")
	assert(
		state.approval.agentRequestID == APPROVAL_TEST_REQUEST_ID,
		"expected the first approval to stay pending",
	)
	assert(
		app_resolve_approval(&state, APPROVAL_TEST_REQUEST_ID, .Deny) == .Resolved,
		"expected the first approval to resolve",
	)
	_ = t
}
