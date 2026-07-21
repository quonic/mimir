package main

import "core:strings"

Permission_Effect :: enum int {
	Read = 0,
	Write,
	Execute,
	Remote,
}

Permission_Grant_Kind :: enum int {
	Directory_Subtree = 0,
	Command_Prefix,
	MCP_Server,
}

Permission_Action :: struct {
	effect:                Permission_Effect,
	projectRoot:           string,
	targetPath:            string,
	targetPathOwned:       bool,
	command:               string,
	shell:                 string,
	workingDirectory:      string,
	workingDirectoryOwned: bool,
	hasCustomEnvironment:  bool,
	mcpServer:             string,
}

permission_action_destroy :: proc(action: ^Permission_Action, allocator := context.allocator) {
	if action.targetPathOwned && action.targetPath != "" {
		delete(action.targetPath, allocator)
	}
	if action.workingDirectoryOwned && action.workingDirectory != "" {
		delete(action.workingDirectory, allocator)
	}
}

Permission_Grant :: struct {
	kind:        Permission_Grant_Kind,
	projectRoot: string,
	directory:   string,
	command:     string,
	shell:       string,
	mcpServer:   string,
}

permission_grant_destroy :: proc(grant: ^Permission_Grant, allocator := context.allocator) {
	if grant.projectRoot != "" {
		delete(grant.projectRoot, allocator)
	}
	if grant.directory != "" {
		delete(grant.directory, allocator)
	}
	if grant.command != "" {
		delete(grant.command, allocator)
	}
	if grant.shell != "" {
		delete(grant.shell, allocator)
	}
	if grant.mcpServer != "" {
		delete(grant.mcpServer, allocator)
	}
}

Permission_Decision :: enum int {
	Denied = 0,
	Allowed_Read_Only,
	Allowed_Session,
	Allowed_Persistent,
	Approval_Required,
}

permission_normalize_absolute_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if len(path) == 0 || path[0] != '/' {
		return "", false
	}

	parts := strings.split(path, "/", allocator)
	defer delete(parts, allocator)
	segments := make([dynamic]string, 0, len(parts), allocator)
	defer delete(segments)
	for part in parts {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			return "", false
		}
		append(&segments, part)
	}
	joined := strings.join(segments[:], "/", allocator)
	defer delete(joined, allocator)
	return strings.concatenate({"/", joined}, allocator), true
}

permission_resolve_project_path :: proc(
	projectRoot, requestedPath: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	root, rootOK := permission_normalize_absolute_path(projectRoot, allocator)
	if !rootOK || requestedPath == "" {
		return "", false
	}
	defer delete(root, allocator)

	if requestedPath[0] == '/' {
		return permission_normalize_absolute_path(requestedPath, allocator)
	}
	joined := strings.concatenate({root, "/", requestedPath}, allocator)
	defer delete(joined, allocator)
	return permission_normalize_absolute_path(joined, allocator)
}

permission_path_is_within_project :: proc(projectRoot, resolvedPath: string) -> bool {
	if projectRoot == "/" {
		return len(resolvedPath) > 0 && resolvedPath[0] == '/'
	}
	if resolvedPath == projectRoot {
		return true
	}
	return(
		len(resolvedPath) > len(projectRoot) &&
		strings.starts_with(resolvedPath, projectRoot) &&
		resolvedPath[len(projectRoot)] == '/' \
	)
}

permission_directory_contains_path :: proc(directory, path: string) -> bool {
	return permission_path_is_within_project(directory, path)
}

permission_grant_matches_action :: proc(
	grant: Permission_Grant,
	action: Permission_Action,
) -> bool {
	if grant.projectRoot != action.projectRoot {
		return false
	}

	switch grant.kind {
	case .Directory_Subtree:
		return(
			action.effect == .Write &&
			permission_directory_contains_path(grant.directory, action.targetPath) \
		)
	case .Command_Prefix:
		return(
			action.effect == .Execute &&
			!action.hasCustomEnvironment &&
			action.workingDirectory == action.projectRoot &&
			action.shell == grant.shell &&
			strings.starts_with(action.command, grant.command) \
		)
	case .MCP_Server:
		return action.effect == .Remote && action.mcpServer == grant.mcpServer
	}
	return false
}

permission_action_decision :: proc(
	action: Permission_Action,
	persistentGrants: []Permission_Grant,
	sessionGrants: []Permission_Grant,
) -> Permission_Decision {
	if action.effect == .Read {
		if permission_path_is_within_project(action.projectRoot, action.targetPath) {
			return .Allowed_Read_Only
		}
		return .Denied
	}

	for grant in sessionGrants {
		if permission_grant_matches_action(grant, action) {
			return .Allowed_Session
		}
	}
	for grant in persistentGrants {
		if permission_grant_matches_action(grant, action) {
			return .Allowed_Persistent
		}
	}
	return .Approval_Required
}
