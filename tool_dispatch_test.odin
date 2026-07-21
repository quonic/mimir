package main

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_tool_dispatcher_allows_project_read_only :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(
		&dispatcher,
		Tool_Call{id = "read_file", filePath = "src/main.odin"},
	)
	assert(decision == .Allowed_Read_Only, "expected project file read to be allowed")
	_ = t
}

@(test)
test_tool_dispatcher_requires_approval_for_write_without_grant :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(
		&dispatcher,
		Tool_Call{id = "write_file", filePath = "generated/output.txt"},
	)
	assert(decision == .Approval_Required, "expected project write to require approval")
	_ = t
}

@(test)
test_tool_dispatch_prepare_preserves_approval_action :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	result := tool_dispatch_prepare(
		&dispatcher,
		Tool_Call{id = "write_file", filePath = "generated/output.txt"},
	)
	defer tool_dispatch_result_destroy(&result, context.allocator)
	assert(result.decision == .Approval_Required, "expected write to require approval")
	assert(result.actionOK, "expected valid write to retain its canonical action")
	assert(
		result.action.targetPath == "/workspace/project/generated/output.txt",
		"expected action path to be resolved before approval",
	)
	_ = t
}

@(test)
test_tool_dispatch_grant_from_write_action_uses_parent_directory :: proc(t: ^testing.T) {
	action := Permission_Action {
		effect      = .Write,
		projectRoot = "/workspace/project",
		targetPath  = "/workspace/project/generated/output.txt",
	}
	grant, ok := tool_dispatch_grant_from_action(action, context.allocator)
	defer permission_grant_destroy(&grant, context.allocator)
	assert(ok, "expected write action to derive reusable grant")
	assert(grant.kind == .Directory_Subtree, "expected directory subtree grant")
	assert(grant.directory == "/workspace/project/generated", "expected parent directory grant")
	_ = t
}

@(test)
test_tool_dispatcher_allows_shell_listing_as_read_only :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(&dispatcher, Tool_Call{id = "list_available_shells"})
	assert(decision == .Allowed_Read_Only, "expected shell listing to be read-only")
	_ = t
}

@(test)
test_builtin_ai_tool_definitions_cover_dispatcher_tools :: proc(t: ^testing.T) {
	definitions := builtin_ai_tool_definitions(context.allocator)
	defer delete(definitions)
	assert(len(definitions) == 6, "expected every built-in tool to be advertised")
	assert(definitions[0].name == "read_file", "expected read_file tool definition")
	assert(definitions[2].name == "run_command", "expected run_command tool definition")
	assert(
		definitions[3].name == "list_available_shells",
		"expected shell listing tool definition",
	)
	assert(definitions[2].parametersJSON != "", "expected run_command JSON schema")
	_ = t
}

@(test)
test_tool_dispatcher_honors_session_grant :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	grant := Permission_Grant {
		kind        = .Directory_Subtree,
		projectRoot = "/workspace/project",
		directory   = "/workspace/project/generated",
	}
	assert(tool_dispatcher_add_session_grant(&dispatcher, grant), "expected session grant to add")

	decision := tool_dispatch_decide(
		&dispatcher,
		Tool_Call{id = "write_file", filePath = "generated/output.txt"},
	)
	assert(decision == .Allowed_Session, "expected session grant to allow project write")
	_ = t
}

@(test)
test_tool_dispatcher_denies_unknown_tool :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(&dispatcher, Tool_Call{id = "unknown"})
	assert(decision == .Denied, "expected unknown tool to be denied")
	_ = t
}

@(test)
test_tool_dispatcher_does_not_execute_unapproved_write :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "mimir-permission-*", context.allocator)
	assert(err == nil, "expected temporary project directory")
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)

	dispatcher, ok := tool_dispatcher_init(directory, nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	output := tool_dispatch_execute(
		&dispatcher,
		Tool_Call {
			id = "write_file",
			filePath = "blocked.txt",
			content = "must not be written",
			overwrite = "false",
		},
	)
	assert(output == "Permission approval required.", "expected write to await approval")
	blockedPath := strings.concatenate({directory, "/blocked.txt"}, context.allocator)
	defer delete(blockedPath, context.allocator)
	assert(!os.exists(blockedPath), "expected unapproved write not to create a file")
	_ = t
}

@(test)
test_tool_dispatcher_executes_write_allowed_by_persistent_grant :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "mimir-permission-*", context.allocator)
	assert(err == nil, "expected temporary project directory")
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)

	generatedDirectory := strings.concatenate({directory, "/generated"}, context.allocator)
	defer delete(generatedDirectory, context.allocator)
	assert(os.make_directory(generatedDirectory) == nil, "expected generated directory")
	grants := [1]Permission_Grant {
		{kind = .Directory_Subtree, projectRoot = directory, directory = generatedDirectory},
	}

	dispatcher, ok := tool_dispatcher_init(directory, grants[:], context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	output := tool_dispatch_execute(
		&dispatcher,
		Tool_Call {
			id = "write_file",
			filePath = "generated/allowed.txt",
			content = "permitted",
			overwrite = "false",
		},
	)
	assert(output == "File written successfully", "expected persistent grant to execute write")
	allowedPath := strings.concatenate({generatedDirectory, "/allowed.txt"}, context.allocator)
	defer delete(allowedPath, context.allocator)
	assert(os.exists(allowedPath), "expected persistent grant to create scoped file")
	_ = t
}
