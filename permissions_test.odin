package main

import "core:testing"

@(test)
test_permission_resolve_project_path_rejects_traversal :: proc(t: ^testing.T) {
	path, ok := permission_resolve_project_path("/workspace/project", "src/main.odin")
	defer delete(path, context.allocator)
	assert(ok, "expected project-relative path to resolve")
	assert(path == "/workspace/project/src/main.odin", "expected resolved project path")

	_, traversalOK := permission_resolve_project_path("/workspace/project", "../secret.txt")
	assert(!traversalOK, "expected traversal path to be rejected")

	externalPath, externalOK := permission_resolve_project_path("/workspace/project", "/tmp/file")
	defer delete(externalPath, context.allocator)
	assert(externalOK, "expected absolute path to normalize")
	assert(
		!permission_path_is_within_project("/workspace/project", externalPath),
		"expected external path to be outside the project",
	)
	_ = t
}

@(test)
test_permission_directory_grant_matches_project_subtree :: proc(t: ^testing.T) {
	grant := Permission_Grant {
		kind        = .Directory_Subtree,
		projectRoot = "/workspace/project",
		directory   = "/workspace/project/generated",
	}
	action := Permission_Action {
		effect      = .Write,
		projectRoot = "/workspace/project",
		targetPath  = "/workspace/project/generated/output.txt",
	}
	assert(permission_grant_matches_action(grant, action), "expected subtree write grant to match")

	action.targetPath = "/workspace/project/source/main.odin"
	assert(
		!permission_grant_matches_action(grant, action),
		"expected grant to reject sibling path",
	)
	_ = t
}

@(test)
test_permission_command_grant_requires_project_shell_and_safe_environment :: proc(t: ^testing.T) {
	grant := Permission_Grant {
		kind        = .Command_Prefix,
		projectRoot = "/workspace/project",
		command     = "odin test",
		shell       = "/bin/sh",
	}
	action := Permission_Action {
		effect           = .Execute,
		projectRoot      = "/workspace/project",
		command          = "odin test ./...",
		shell            = "/bin/sh",
		workingDirectory = "/workspace/project",
	}
	assert(permission_grant_matches_action(grant, action), "expected matching command prefix")

	action.hasCustomEnvironment = true
	assert(
		!permission_grant_matches_action(grant, action),
		"expected custom environment to require approval",
	)
	_ = t
}

@(test)
test_permission_remote_grant_matches_server :: proc(t: ^testing.T) {
	grant := Permission_Grant {
		kind        = .MCP_Server,
		projectRoot = "/workspace/project",
		mcpServer   = "github",
	}
	action := Permission_Action {
		effect      = .Remote,
		projectRoot = "/workspace/project",
		mcpServer   = "github",
	}
	assert(permission_grant_matches_action(grant, action), "expected matching MCP server grant")
	action.mcpServer = "filesystem"
	assert(
		!permission_grant_matches_action(grant, action),
		"expected different MCP server to be denied",
	)
	_ = t
}
