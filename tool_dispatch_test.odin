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
