package tool_policy

import "core:strings"

Permission_Effect :: enum int {
	Read = 0,
	Write,
	Execute,
}

Permission_Grant_Kind :: enum int {
	Directory_Subtree = 0,
	Command_Prefix,
}

Permission_Action :: struct {
	effect:                Permission_Effect,
	projectRoot:           string,
	targetPath:            string,
	targetPathOwned:       bool,
	command:               string,
	workingDirectory:      string,
	workingDirectoryOwned: bool,
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
}

Permission_Decision :: enum int {
	Denied = 0,
	Allowed_Read_Only,
	Allowed_Session,
	Allowed_Persistent,
	Approval_Required,
}

// Recognizes a `C:\`/`C:/` drive-letter root; UNC and relative-drive paths are not supported.
@(private)
permission_windows_drive_prefix :: proc(path: string) -> (prefix: string, rest: string, ok: bool) {
	if len(path) < 3 {
		return "", "", false
	}
	letter := path[0]
	if !((letter >= 'A' && letter <= 'Z') || (letter >= 'a' && letter <= 'z')) {
		return "", "", false
	}
	if path[1] != ':' || (path[2] != '\\' && path[2] != '/') {
		return "", "", false
	}
	return path[:2], path[3:], true
}

permission_path_is_absolute :: proc(path: string) -> bool {
	if len(path) > 0 && path[0] == '/' {
		return true
	}
	when ODIN_OS == .Windows {
		_, _, ok := permission_windows_drive_prefix(path)
		return ok
	} else {
		return false
	}
}

@(private)
permission_join_normalized_segments :: proc(
	rest: string,
	separator: string,
	prefix: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	parts := strings.split(rest, separator, allocator)
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
	joined := strings.join(segments[:], separator, allocator)
	defer delete(joined, allocator)
	return strings.concatenate({prefix, separator, joined}, allocator), true
}

permission_normalize_absolute_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if len(path) == 0 {
		return "", false
	}

	when ODIN_OS == .Windows {
		// Windows working directories use drive letters and backslashes (e.g. `C:\Users\me`);
		// forward-slash-rooted paths (as used by project-relative logic and tests) still fall
		// through to the POSIX-style branch below.
		if prefix, rawRest, isWindowsPath := permission_windows_drive_prefix(path); isWindowsPath {
			rest, restAllocated := strings.replace_all(rawRest, "/", "\\", allocator)
			defer if restAllocated {
				delete(rest, allocator)
			}
			return permission_join_normalized_segments(rest, "\\", prefix, allocator)
		}
	}

	if path[0] != '/' {
		return "", false
	}
	return permission_join_normalized_segments(path[1:], "/", "", allocator)
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

	if permission_path_is_absolute(requestedPath) {
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
	if len(resolvedPath) <= len(projectRoot) || !strings.starts_with(resolvedPath, projectRoot) {
		return false
	}
	boundary := resolvedPath[len(projectRoot)]
	when ODIN_OS == .Windows {
		return boundary == '/' || boundary == '\\'
	} else {
		return boundary == '/'
	}
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
			action.workingDirectory == action.projectRoot &&
			strings.starts_with(action.command, grant.command) \
		)
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
