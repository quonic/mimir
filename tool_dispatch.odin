package main

import "core:mem"
import "core:strings"

Tool_Call :: struct {
	callID:           string,
	id:               string,
	filePath:         string,
	directoryPath:    string,
	startLine:        string,
	endLine:          string,
	content:          string,
	overwrite:        string,
	command:          string,
	workingDirectory: string,
	timeout:          int,
	captureOutput:    bool,
	environment:      [dynamic]string,
	shell:            string,
	mcpServer:        string,
}

Tool_Dispatcher :: struct {
	projectRoot:      string,
	persistentGrants: []Permission_Grant,
	sessionGrants:    [dynamic]Permission_Grant,
	allocator:        mem.Allocator,
}

Tool_Dispatch_Result :: struct {
	decision: Permission_Decision,
	action:   Permission_Action,
	actionOK: bool,
}

tool_call_clone :: proc(call: Tool_Call, allocator := context.allocator) -> Tool_Call {
	clone := Tool_Call {
		callID           = strings.clone(call.callID, allocator),
		id               = strings.clone(call.id, allocator),
		filePath         = strings.clone(call.filePath, allocator),
		directoryPath    = strings.clone(call.directoryPath, allocator),
		startLine        = strings.clone(call.startLine, allocator),
		endLine          = strings.clone(call.endLine, allocator),
		content          = strings.clone(call.content, allocator),
		overwrite        = strings.clone(call.overwrite, allocator),
		command          = strings.clone(call.command, allocator),
		workingDirectory = strings.clone(call.workingDirectory, allocator),
		timeout          = call.timeout,
		captureOutput    = call.captureOutput,
		shell            = strings.clone(call.shell, allocator),
		mcpServer        = strings.clone(call.mcpServer, allocator),
		environment      = make([dynamic]string, 0, len(call.environment), allocator),
	}
	for entry in call.environment {
		append(&clone.environment, strings.clone(entry, allocator))
	}
	return clone
}

tool_call_destroy :: proc(call: ^Tool_Call, allocator := context.allocator) {
	delete(call.callID, allocator)
	delete(call.id, allocator)
	delete(call.filePath, allocator)
	delete(call.directoryPath, allocator)
	delete(call.startLine, allocator)
	delete(call.endLine, allocator)
	delete(call.content, allocator)
	delete(call.overwrite, allocator)
	delete(call.command, allocator)
	delete(call.workingDirectory, allocator)
	delete(call.shell, allocator)
	delete(call.mcpServer, allocator)
	for entry in call.environment {
		delete(entry, allocator)
	}
	delete(call.environment)
}

tool_dispatch_result_destroy :: proc(
	result: ^Tool_Dispatch_Result,
	allocator := context.allocator,
) {
	if result.actionOK {
		permission_action_destroy(&result.action, allocator)
	}
	result^ = {}
}

tool_dispatcher_init :: proc(
	projectRoot: string,
	persistentGrants: []Permission_Grant,
	allocator := context.allocator,
) -> (
	Tool_Dispatcher,
	bool,
) {
	canonicalRoot, rootOK := permission_normalize_absolute_path(projectRoot, allocator)
	if !rootOK {
		return Tool_Dispatcher{}, false
	}
	return Tool_Dispatcher {
			projectRoot = canonicalRoot,
			persistentGrants = persistentGrants,
			sessionGrants = make([dynamic]Permission_Grant, 0, 0, allocator),
			allocator = allocator,
		},
		true
}

tool_dispatcher_destroy :: proc(dispatcher: ^Tool_Dispatcher) {
	if dispatcher.projectRoot != "" {
		delete(dispatcher.projectRoot, dispatcher.allocator)
	}
	for &grant in dispatcher.sessionGrants {
		permission_grant_destroy(&grant, dispatcher.allocator)
	}
	delete(dispatcher.sessionGrants)
}

tool_dispatcher_add_session_grant :: proc(
	dispatcher: ^Tool_Dispatcher,
	grant: Permission_Grant,
) -> bool {
	if grant.projectRoot != dispatcher.projectRoot {
		return false
	}

	clone := Permission_Grant {
		kind        = grant.kind,
		projectRoot = strings.clone(grant.projectRoot, dispatcher.allocator),
		directory   = strings.clone(grant.directory, dispatcher.allocator),
		command     = strings.clone(grant.command, dispatcher.allocator),
		shell       = strings.clone(grant.shell, dispatcher.allocator),
		mcpServer   = strings.clone(grant.mcpServer, dispatcher.allocator),
	}
	append(&dispatcher.sessionGrants, clone)
	return true
}

tool_dispatch_build_action :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> (
	Permission_Action,
	bool,
) {
	action := Permission_Action {
		projectRoot = dispatcher.projectRoot,
	}
	switch call.id {
	case "read_file", "get_file_info":
		resolvedPath, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return Permission_Action{}, false
		}
		action.effect = .Read
		action.targetPath = resolvedPath
		action.targetPathOwned = true
	case "list_available_shells":
		action.effect = .Read
		action.targetPath = dispatcher.projectRoot
	case "list_directory":
		resolvedPath, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.directoryPath,
			dispatcher.allocator,
		)
		if !pathOK {
			return Permission_Action{}, false
		}
		action.effect = .Read
		action.targetPath = resolvedPath
		action.targetPathOwned = true
	case "write_file":
		resolvedPath, pathOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK || !permission_path_is_within_project(dispatcher.projectRoot, resolvedPath) {
			if resolvedPath != "" {
				delete(resolvedPath, dispatcher.allocator)
			}
			return Permission_Action{}, false
		}
		action.effect = .Write
		action.targetPath = resolvedPath
		action.targetPathOwned = true
	case "run_command":
		if call.command == "" || call.shell == "" {
			return Permission_Action{}, false
		}
		action.effect = .Execute
		action.command = call.command
		action.shell = call.shell
		action.hasCustomEnvironment = len(call.environment) > 0
		if call.workingDirectory == "" {
			action.workingDirectory = dispatcher.projectRoot
			break
		}
		resolvedDirectory, directoryOK := permission_resolve_project_path(
			dispatcher.projectRoot,
			call.workingDirectory,
			dispatcher.allocator,
		)
		if !directoryOK ||
		   !permission_path_is_within_project(dispatcher.projectRoot, resolvedDirectory) {
			if resolvedDirectory != "" {
				delete(resolvedDirectory, dispatcher.allocator)
			}
			return Permission_Action{}, false
		}
		action.workingDirectory = resolvedDirectory
		action.workingDirectoryOwned = true
	case "mcp":
		if call.mcpServer == "" {
			return Permission_Action{}, false
		}
		action.effect = .Remote
		action.mcpServer = call.mcpServer
	case:
		return Permission_Action{}, false
	}
	return action, true
}

tool_dispatch_prepare :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> Tool_Dispatch_Result {
	action, actionOK := tool_dispatch_build_action(dispatcher, call)
	if !actionOK {
		return Tool_Dispatch_Result{decision = .Denied}
	}
	return Tool_Dispatch_Result {
		decision = permission_action_decision(
			action,
			dispatcher.persistentGrants,
			dispatcher.sessionGrants[:],
		),
		action = action,
		actionOK = true,
	}
}

tool_dispatch_decide :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> Permission_Decision {
	result := tool_dispatch_prepare(dispatcher, call)
	defer tool_dispatch_result_destroy(&result, dispatcher.allocator)
	return result.decision
}

tool_dispatch_grant_from_action :: proc(
	action: Permission_Action,
	allocator := context.allocator,
) -> (
	Permission_Grant,
	bool,
) {
	grant := Permission_Grant {
		projectRoot = strings.clone(action.projectRoot, allocator),
	}
	switch action.effect {
	case .Write:
		lastSlash := -1
		for index := 0; index < len(action.targetPath); index += 1 {
			if action.targetPath[index] == '/' {
				lastSlash = index
			}
		}
		if lastSlash <= 0 {
			permission_grant_destroy(&grant, allocator)
			return Permission_Grant{}, false
		}
		grant.kind = .Directory_Subtree
		grant.directory = strings.clone(action.targetPath[:lastSlash], allocator)
	case .Execute:
		if action.hasCustomEnvironment || action.workingDirectory != action.projectRoot {
			permission_grant_destroy(&grant, allocator)
			return Permission_Grant{}, false
		}
		grant.kind = .Command_Prefix
		grant.command = strings.clone(action.command, allocator)
		grant.shell = strings.clone(action.shell, allocator)
	case .Remote:
		grant.kind = .MCP_Server
		grant.mcpServer = strings.clone(action.mcpServer, allocator)
	case .Read:
		permission_grant_destroy(&grant, allocator)
		return Permission_Grant{}, false
	}
	return grant, true
}

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
		return read_file_tool_proc(path, call.startLine, call.endLine)
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
		return run_command_tool_proc(
			call.command,
			workingDirectory,
			call.timeout,
			call.captureOutput,
			call.environment,
			call.shell,
		)
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
