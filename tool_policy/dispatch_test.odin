package tool_policy

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
test_tool_dispatcher_allows_project_code_search_as_read_only :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(
		&dispatcher,
		Tool_Call{id = "search_code", query = "tool dispatch"},
	)
	assert(decision == .Allowed_Read_Only, "expected project code search to be read-only")
	_ = t
}

@(test)
test_tool_dispatcher_allows_project_code_lookup_as_read_only :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(
		&dispatcher,
		Tool_Call{id = "find_code", query = "write_decimal"},
	)
	assert(decision == .Allowed_Read_Only, "expected project code lookup to be read-only")
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
test_tool_dispatcher_requires_approval_for_create_subagent :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	result := tool_dispatch_prepare(
		&dispatcher,
		Tool_Call{id = "create_subagent", task = "Summarize the README"},
	)
	defer tool_dispatch_result_destroy(&result, context.allocator)
	assert(result.decision == .Approval_Required, "expected create_subagent to require approval")
	assert(result.actionOK, "expected create_subagent to resolve to a valid action")
	assert(
		result.action.effect == .Execute,
		"expected create_subagent to reuse the Execute effect",
	)
	assert(
		result.action.command == "Summarize the README",
		"expected the task text to be surfaced for the approval prompt",
	)
	_ = t
}

@(test)
test_tool_dispatcher_denies_create_subagent_without_task :: proc(t: ^testing.T) {
	dispatcher, ok := tool_dispatcher_init("/workspace/project", nil, context.allocator)
	defer tool_dispatcher_destroy(&dispatcher)
	assert(ok, "expected dispatcher project root to initialize")

	decision := tool_dispatch_decide(&dispatcher, Tool_Call{id = "create_subagent"})
	assert(decision == .Denied, "expected create_subagent without a task to be denied")
	_ = t
}
