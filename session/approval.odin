package session

import "../agent"
import "../ai"
import "../approval_safety"
import "../settings"
import "../tool_policy"
import "core:mem"
import "core:strings"

// The approval decision logic. These procedures decide and settle tool approvals: the approval
// method, the safety verdict and the grants. A front end shows a pending approval from the
// Approval_Requested event and answers it with session_resolve_approval.

// Approval_Choice is the answer to a pending approval.
Approval_Choice :: enum int {
	Allow_Once = 0,
	Allow_Session,
	Allow_Always,
	Deny,
}

// Pending_Approval is the tool call that waits for an approval decision.
Pending_Approval :: struct {
	call:            tool_policy.Tool_Call,
	callOwned:       bool,
	prepared:        tool_policy.Tool_Dispatch_Result,
	preparedOwned:   bool,
	agentID:         agent.Agent_ID,
	// The tool request ID of the agent runtime: the model's ID. The session's tool call ID is
	// call.callID.
	agentRequestID:  string,
	// True when the approval method uses the safety classifier for this call.
	safetyRequested: bool,
	safety:          approval_safety.State,
}

// Approval_Request_Result tells the caller of session_request_approval what happened to the
// call.
Approval_Request_Result :: enum int {
	// The call could not become a pending approval. Nothing was changed.
	Rejected = 0,
	// The call is pending and waits for a choice from the front end.
	Awaiting_Choice,
	// The approval method settled the call. Nothing is pending.
	Settled,
}

Approval_Safety_Model :: struct {
	provider: settings.Provider_Config,
	model:    string,
}

// Reports whether a tool call waits for an approval decision.
pending_approval_active :: proc(approval: ^Pending_Approval) -> bool {
	return approval.callOwned && approval.preparedOwned
}

pending_approval_destroy :: proc(approval: ^Pending_Approval, allocator: mem.Allocator) {
	approval_safety.destroy(&approval.safety)
	if approval.callOwned {
		tool_policy.tool_call_destroy(&approval.call, allocator)
	}
	if approval.preparedOwned {
		tool_policy.tool_dispatch_result_destroy(&approval.prepared, allocator)
	}
	delete(approval.agentRequestID, allocator)
	approval^ = {}
}

session_clear_approval :: proc(session: ^Session) {
	pending_approval_destroy(&session.approval, session.dispatcher.allocator)
}

// Makes call the pending approval and starts the safety classifier when the approval method
// uses it. It does not run the approval method. It returns false and changes nothing when the
// dispatcher is not ready, another approval is pending, or the call does not need approval.
session_prepare_approval :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) -> bool {
	if !session.dispatcherReady || pending_approval_active(&session.approval) {
		return false
	}
	allocator := session.dispatcher.allocator

	approvalCall := tool_policy.tool_call_clone(call, allocator)
	prepared := tool_policy.tool_dispatch_prepare(&session.dispatcher, approvalCall)
	if prepared.decision != .Approval_Required || !prepared.actionOK {
		tool_policy.tool_dispatch_result_destroy(&prepared, allocator)
		tool_policy.tool_call_destroy(&approvalCall, allocator)
		return false
	}

	session_clear_approval(session)
	approval := &session.approval
	approval.call = approvalCall
	approval.callOwned = true
	approval.prepared = prepared
	approval.preparedOwned = true
	approval.agentID = agentID
	if requestID != "" {
		approval.agentRequestID = strings.clone(requestID, allocator)
	}
	if session.approvalMethod == .Approve_Safe ||
	   (session.approvalMethod == .Always_Ask && prepared.action.effect == .Execute) {
		approval.safetyRequested = true
		pending_approval_start_safety(session, allocator)
	}
	return true
}

// Makes an agent tool call the pending approval and runs the approval method. Approve_All and
// Deny_All settle the call here, without an Approval_Requested event. Otherwise the call waits
// for a choice, or, under Approve_Safe, for the safety verdict (see
// session_poll_pending_approval).
session_request_approval :: proc(
	session: ^Session,
	call: tool_policy.Tool_Call,
	agentID: agent.Agent_ID,
	requestID: string,
) -> Approval_Request_Result {
	if !session_prepare_approval(session, call, agentID, requestID) {
		return .Rejected
	}
	session_emit_tool_call_updated(session, call.callID, .Awaiting_Approval)
	switch session.approvalMethod {
	case .Approve_All:
		_ = session_settle_approval(session, .Allow_Once, false)
		return .Settled
	case .Deny_All:
		_ = session_settle_approval(session, .Deny, false)
		return .Settled
	case .Always_Ask, .Approve_Safe:
	}
	allocator := session.allocator
	session_emit(
		session,
		Approval_Requested {
			toolCallID = strings.clone(session.approval.call.callID, allocator),
			action = permission_action_copy(session.approval.prepared.action, allocator),
			safety = pending_approval_safety(&session.approval, allocator),
		},
	)
	_ = session_apply_safe_approval(session)
	if pending_approval_active(&session.approval) {
		return .Awaiting_Choice
	}
	return .Settled
}

// Under Approve_Safe, approves the pending approval when the safety verdict is safe. It
// returns true when it approved the call.
session_apply_safe_approval :: proc(session: ^Session) -> bool {
	if !pending_approval_active(&session.approval) || session.approvalMethod != .Approve_Safe {
		return false
	}
	approval := &session.approval
	if !safety_allows_automatic_approval(
		pending_approval_safety_ready(approval),
		pending_approval_safety_unavailable(approval),
		pending_approval_safety_verdict(approval),
	) {
		return false
	}
	_ = session_settle_approval(session, .Allow_Once, true)
	return true
}

safety_allows_automatic_approval :: proc(
	ready, unavailable: bool,
	verdict: approval_safety.Verdict,
) -> bool {
	return ready && !unavailable && verdict == .Safe
}

// Advances the safety classifier of the pending approval. When the classifier finishes, it
// emits Approval_Safety_Updated and, under Approve_Safe, approves a safe call. It returns true
// when the classifier finished.
session_poll_pending_approval :: proc(session: ^Session) -> bool {
	approval := &session.approval
	if !pending_approval_active(approval) || !approval_safety.poll(&approval.safety) {
		return false
	}
	allocator := session.allocator
	session_emit(
		session,
		Approval_Safety_Updated {
			toolCallID = strings.clone(approval.call.callID, allocator),
			safety = pending_approval_safety(approval, allocator),
		},
	)
	_ = session_apply_safe_approval(session)
	return true
}

// Applies choice to the pending approval with the tool call ID toolCallID.
session_apply_approval_choice :: proc(
	session: ^Session,
	toolCallID: string,
	choice: Approval_Choice,
) -> Session_Error {
	if !pending_approval_active(&session.approval) {
		return .No_Pending_Approval
	}
	if toolCallID != session.approval.call.callID {
		return .Unknown_Tool_Call
	}
	return session_settle_approval(session, choice, true)
}

// Applies choice to the pending approval. Allow_Session adds a grant to the dispatcher;
// Allow_Always appends a grant to the config and saves the config. When announce is true, it
// emits Approval_Resolved once the call is no longer pending.
session_settle_approval :: proc(
	session: ^Session,
	choice: Approval_Choice,
	announce: bool,
) -> Session_Error {
	approval := &session.approval
	allocator := session.dispatcher.allocator
	toolCallID := approval.call.callID
	if choice == .Deny {
		output := "Permission denied."
		session_emit_tool_call_updated(session, toolCallID, .Denied, output)
		if !agent.agent_id_is_none(approval.agentID) && approval.agentRequestID != "" {
			_ = agent.runtime_resolve_tool(
				&session.host.runtime,
				approval.agentID,
				approval.agentRequestID,
				.Denied,
				output,
			)
		}
		session_emit_notice(session, "Tool call denied")
		session_finish_approval(session, choice, announce)
		return .None
	}

	if choice == .Allow_Session || choice == .Allow_Always {
		grant, grantOK := tool_policy.tool_dispatch_grant_from_action(
			approval.prepared.action,
			allocator,
		)
		if !grantOK {
			session_emit_notice(session, "Tool call requires one-time approval", .Warning)
			return .Approval_Not_Applied
		}

		if choice == .Allow_Session {
			grantOK = tool_policy.tool_dispatcher_add_session_grant(&session.dispatcher, grant)
			tool_policy.permission_grant_destroy(&grant, allocator)
		} else {
			config := session.config
			append(&config.permissionGrants, grant)
			if session.configHome != "" &&
			   settings.save_config_to_file(session.configHome, config^) != .None {
				grant = pop(&config.permissionGrants)
				tool_policy.permission_grant_destroy(&grant, allocator)
				session_emit_notice(session, "Permission grant could not be saved", .Error)
				return .Approval_Not_Applied
			}
		}

		if !grantOK {
			session_emit_notice(session, "Permission grant could not be added", .Error)
			return .Approval_Not_Applied
		}
	}

	if agent.agent_id_is_none(approval.agentID) || approval.agentRequestID == "" {
		session_emit_notice(session, "Tool call is no longer active", .Warning)
		session_finish_approval(session, choice, announce)
		return .None
	}

	session_emit_tool_call_updated(session, toolCallID, .Running)
	session_run_allowed_tool(session, approval.call, approval.agentID, approval.agentRequestID)
	session_finish_approval(session, choice, announce)
	return .None
}

// Clears the pending approval and, when announce is true, emits Approval_Resolved.
session_finish_approval :: proc(session: ^Session, choice: Approval_Choice, announce: bool) {
	if announce {
		session_emit(
			session,
			Approval_Resolved {
				toolCallID = strings.clone(session.approval.call.callID, session.allocator),
				choice = choice,
			},
		)
	}
	session_clear_approval(session)
}

// Starts the safety classifier for the action of the pending approval, with the safety model
// of the config. When no safety model is available, it marks the safety state unavailable.
pending_approval_start_safety :: proc(session: ^Session, allocator: mem.Allocator) {
	approval := &session.approval
	safety := &approval.safety
	approval_safety.init(safety, allocator)

	safetyModel, safetyModelOK := approval_safety_model_from_config(
		session.config^,
		session.providerName,
		session.model,
	)
	if !safetyModelOK {
		approval_safety.mark_unavailable(safety, allocator)
		return
	}
	client, clientErr := ai.new_client(safetyModel.provider.name, safetyModel.provider.apiKey)
	if clientErr != .None {
		approval_safety.mark_unavailable(safety, allocator)
		return
	}

	_ = approval_safety.start(
		safety,
		approval_safety.Start_Input {
			client = client,
			model = safetyModel.model,
			action = approval.prepared.action,
		},
	)
}

// Returns the safety model: the explicit safety selection of config, or else the chat model
// providerName and model.
approval_safety_model_from_config :: proc(
	config: settings.Mimir_Config,
	providerName, model: string,
) -> (
	Approval_Safety_Model,
	bool,
) {
	providerName := providerName
	model := model
	explicitSafetyModel := config.safetyProvider != "" || config.safetyModel != ""
	if explicitSafetyModel {
		if config.safetyProvider == "" || config.safetyModel == "" {
			return Approval_Safety_Model{}, false
		}
		providerName = config.safetyProvider
		model = config.safetyModel
	}
	if providerName == "" {
		return Approval_Safety_Model{}, false
	}
	provider, providerOK := settings.config_find_provider(config, providerName)
	if !providerOK || !provider.enabled {
		return Approval_Safety_Model{}, false
	}
	if model == "" && !explicitSafetyModel {
		model = provider.model
	}
	if model == "" {
		return Approval_Safety_Model{}, false
	}
	return Approval_Safety_Model{provider = provider, model = model}, true
}

// Reports whether the safety classifier of approval does not run.
pending_approval_safety_ready :: proc(approval: ^Pending_Approval) -> bool {
	return !approval_safety.is_active(&approval.safety)
}

pending_approval_safety_unavailable :: proc(approval: ^Pending_Approval) -> bool {
	return approval_safety.is_unavailable(&approval.safety)
}

pending_approval_safety_verdict :: proc(approval: ^Pending_Approval) -> approval_safety.Verdict {
	return approval_safety.verdict(&approval.safety)
}

// Returns the safety state of approval as event data. The response is allocated with
// allocator.
pending_approval_safety :: proc(
	approval: ^Pending_Approval,
	allocator := context.allocator,
) -> Approval_Safety {
	if !approval.safetyRequested {
		return Approval_Safety{status = .Not_Checked}
	}
	if !pending_approval_safety_ready(approval) {
		return Approval_Safety{status = .Checking}
	}
	if pending_approval_safety_unavailable(approval) {
		return Approval_Safety{status = .Unavailable}
	}
	return Approval_Safety {
		status = .Checked,
		verdict = pending_approval_safety_verdict(approval),
		response = approval_safety.response(&approval.safety, allocator),
	}
}
