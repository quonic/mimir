package tool_policy

import "core:testing"

@(test)
test_permission_normalize_windows_drive_path :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		path, ok := permission_normalize_absolute_path(`C:\Users\me\work\mimir`)
		defer delete(path, context.allocator)
		assert(ok, "expected drive-letter path to normalize")
		assert(path == `C:\Users\me\work\mimir`, "expected round-trip drive-letter path")

		mixed, mixedOK := permission_normalize_absolute_path("C:/Users/me/work/mimir")
		defer delete(mixed, context.allocator)
		assert(mixedOK, "expected forward-slash drive path to normalize")
		assert(
			mixed == `C:\Users\me\work\mimir`,
			"expected forward slashes rewritten to backslashes",
		)

		root, rootOK := permission_normalize_absolute_path(`C:\`)
		defer delete(root, context.allocator)
		assert(rootOK, "expected drive root to normalize")
		assert(root == `C:\`, "expected drive root to round-trip")

		resolved, resolvedOK := permission_resolve_project_path(`C:\work\mimir`, "src/main.odin")
		defer delete(resolved, context.allocator)
		assert(resolvedOK, "expected project-relative path to resolve under a drive root")
		assert(
			resolved == `C:\work\mimir\src\main.odin`,
			"expected resolved path to use backslashes",
		)
		assert(
			permission_path_is_within_project(`C:\work\mimir`, resolved),
			"expected resolved path to be within the drive-letter project root",
		)
	}
	_ = t
}

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
test_permission_command_grant_requires_project_shell :: proc(t: ^testing.T) {
	grant := Permission_Grant {
		kind        = .Command_Prefix,
		projectRoot = "/workspace/project",
		command     = "odin test",
	}
	action := Permission_Action {
		effect           = .Execute,
		projectRoot      = "/workspace/project",
		command          = "odin test ./...",
		workingDirectory = "/workspace/project",
	}
	assert(permission_grant_matches_action(grant, action), "expected matching command prefix")
	_ = t
}
