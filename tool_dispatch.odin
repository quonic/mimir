package main

import "core:mem"
import "core:strings"

Tool_Call :: struct {
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

tool_dispatch_decide :: proc(
	dispatcher: ^Tool_Dispatcher,
	call: Tool_Call,
) -> Permission_Decision {
	action, actionOK := tool_dispatch_build_action(dispatcher, call)
	if !actionOK {
		return .Denied
	}
	defer permission_action_destroy(&action, dispatcher.allocator)
	return permission_action_decision(
		action,
		dispatcher.persistentGrants,
		dispatcher.sessionGrants[:],
	)
}

tool_dispatch_execute :: proc(dispatcher: ^Tool_Dispatcher, call: Tool_Call) -> string {
	decision := tool_dispatch_decide(dispatcher, call)
	switch decision {
	case .Denied:
		return "Permission denied."
	case .Approval_Required:
		return "Permission approval required."
	case .Allowed_Read_Only, .Allowed_Session, .Allowed_Persistent:
	// The decision has canonicalized and confined the tool inputs to the project.
	case:
		return "Permission denied."
	}

	switch call.id {
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
