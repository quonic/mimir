package main

// Re-export types and functions from tool_policy for backward compatibility
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
) -> (Tool_Dispatcher, bool) {
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
) -> (Permission_Grant, bool) {
	return tool_policy.tool_dispatch_grant_from_action(action, allocator)
}

tool_dispatch_result_destroy :: proc(result: ^Tool_Dispatch_Result, allocator := context.allocator) {
	tool_policy.tool_dispatch_result_destroy(result, allocator)
}

// Tool execution functions remain in main as they depend on tools_procs.odin
// These are NOT part of the extracted policy package per issue non-goals

tool_dispatch_execute_approved :: proc(dispatcher: ^Tool_Dispatcher, call: Tool_Call) -> string {
	prepared := tool_dispatch_prepare(dispatcher, call)
	defer tool_dispatch_result_destroy(&prepared, dispatcher.allocator)
	switch prepared.decision {
	case .Denied:
		return "Permission denied."
	case .Approval_Required, .Allowed_Read_Only, .Allowed_Session, .Allowed_Persistent:
	// The caller has either received policy approval or explicitly authorized this call once.
	case:
		return "Permission denied."
	}

	switch call.id {
	case "list_available_shells":
		return list_available_shells_tool_proc()
	case "read_file":
		path, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return read_file_tool_proc(path)
	case "write_file":
		path, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return write_file_tool_proc(path, call.content, call.overwrite)
	case "list_directory":
		path, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.directoryPath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return list_directory_tool_proc(path)
	case "get_file_info":
		path, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return get_file_info_tool_proc(path)
	case "run_command":
		workingDirectory := dispatcher.projectRoot
		if call.workingDirectory != "" {
			resolvedDirectory, directoryOK := permission_resolve_project_path(
				dispatcher.projectRoot,
				call.workingDirectory,
				dispatcher.allocator,
			)
			if !directoryOK {
				return "Permission denied."
			}
			defer delete(resolvedDirectory, dispatcher.allocator)
			workingDirectory = resolvedDirectory
		}
		return run_command_tool_proc(call.command, workingDirectory, call.timeout)
	case "mcp":
		return "MCP tool dispatch is not implemented."
	}
	return "Permission denied."
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