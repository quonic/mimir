package main

// Re-export types and functions from tool_policy package for backward compatibility
import tool_policy "./tool_policy"

Permission_Effect :: tool_policy.Permission_Effect
Permission_Grant_Kind :: tool_policy.Permission_Grant_Kind
Permission_Action :: tool_policy.Permission_Action
Permission_Grant :: tool_policy.Permission_Grant
Permission_Decision :: tool_policy.Permission_Decision

permission_action_destroy :: proc(action: ^Permission_Action, allocator := context.allocator) {
	tool_policy.permission_action_destroy(action, allocator)
}

permission_grant_destroy :: proc(grant: ^Permission_Grant, allocator := context.allocator) {
	tool_policy.permission_grant_destroy(grant, allocator)
}

permission_normalize_absolute_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	return tool_policy.permission_normalize_absolute_path(path, allocator)
}

permission_resolve_project_path :: proc(
	projectRoot, requestedPath: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	return tool_policy.permission_resolve_project_path(projectRoot, requestedPath, allocator)
}

permission_path_is_within_project :: proc(projectRoot, resolvedPath: string) -> bool {
	return tool_policy.permission_path_is_within_project(projectRoot, resolvedPath)
}

permission_directory_contains_path :: proc(directory, path: string) -> bool {
	return tool_policy.permission_directory_contains_path(directory, path)
}

permission_grant_matches_action :: proc(
	grant: Permission_Grant,
	action: Permission_Action,
) -> bool {
	return tool_policy.permission_grant_matches_action(grant, action)
}

permission_action_decision :: proc(
	action: Permission_Action,
	persistentGrants: []Permission_Grant,
	sessionGrants: []Permission_Grant,
) -> Permission_Decision {
	return tool_policy.permission_action_decision(action, persistentGrants, sessionGrants)
}
