package main

// Re-export types and functions from tool_policy for backward compatibility
import builtin_tools "./builtin_tools"
import tool_policy "./tool_policy"

Tool_Call :: tool_policy.Tool_Call
Tool_Dispatcher :: tool_policy.Tool_Dispatcher
Tool_Dispatch_Result :: tool_policy.Tool_Dispatch_Result

tool_call_clone :: proc(call: Tool_Call, allocator := context.allocator) -> Tool_Call {
	return tool_policy.tool_call_clone(call, allocator)
}

tool_call_destroy :: proc(call: ^Tool_Call, allocator := context.allocator) {
	tool_policy.tool_call_destroy(call, allocator)
}

tool_dispatcher_init :: proc(
	projectRoot: string,
	persistentGrants: []Permission_Grant,
	allocator := context.allocator,
) -> (
	Tool_Dispatcher,
	bool,
) {
	return tool_policy.tool_dispatcher_init(projectRoot, persistentGrants, allocator)
}

tool_dispatcher_destroy :: proc(dispatcher: ^Tool_Dispatcher) {
	tool_policy.tool_dispatcher_destroy(dispatcher)
}

tool_dispatcher_add_session_grant :: proc(
	dispatcher: ^Tool_Dispatcher,
	grant: Permission_Grant,
) -> bool {
	return tool_policy.tool_dispatcher_add_session_grant(dispatcher, grant)
}

tool_dispatch_prepare :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> Tool_Dispatch_Result {
	return tool_policy.tool_dispatch_prepare(dispatcher, call)
}

tool_dispatch_decide :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> Permission_Decision {
	return tool_policy.tool_dispatch_decide(dispatcher, call)
}

tool_dispatch_grant_from_action :: proc(
	action: Permission_Action,
	allocator := context.allocator,
) -> (
	Permission_Grant,
	bool,
) {
	return tool_policy.tool_dispatch_grant_from_action(action, allocator)
}

tool_dispatch_result_destroy :: proc(
	result: ^Tool_Dispatch_Result,
	allocator := context.allocator,
) {
	tool_policy.tool_dispatch_result_destroy(result, allocator)
}

// Tool execution functions delegate to builtin_tools package
// search_code and find_code remain application-provided per issue non-goals

tool_dispatch_execute_approved :: proc(dispatcher: ^Tool_Dispatcher, call: Tool_Call) -> string {
	// Delegate to builtin_tools for builtins (excludes search_code/find_code which are app-provided)
	if call.id != "search_code" && call.id != "find_code" {
		return builtin_tools.execute_builtin_tool(
			dispatcher,
			tool_policy.Tool_Call {
				callID = call.callID,
				id = call.id,
				filePath = call.filePath,
				directoryPath = call.directoryPath,
				startLine = call.startLine,
				endLine = call.endLine,
				content = call.content,
				overwrite = call.overwrite,
				command = call.command,
				workingDirectory = call.workingDirectory,
				timeout = call.timeout,
				mcpServer = call.mcpServer,
				query = call.query,
				maxResults = call.maxResults,
			},
		)
	}

	// search_code and find_code are application-provided (require live code index + ai client)
	return "Tool type not handled by builtin_tools."
}

tool_dispatch_execute :: proc(dispatcher: ^Tool_Dispatcher, call: Tool_Call) -> string {
	prepared := tool_dispatch_prepare(dispatcher, call)
	defer tool_dispatch_result_destroy(&prepared, dispatcher.allocator)
	if prepared.decision == .Denied {
		return "Permission denied."
	}
	if prepared.decision == .Approval_Required {
		return "Permission approval required."
	}
	return tool_dispatch_execute_approved(dispatcher, call)
}
