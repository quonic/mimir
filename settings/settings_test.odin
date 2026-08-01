package settings

import "core:testing"

@(test)
test_mcp_registry_preserves_server_status :: proc(t: ^testing.T) {
	servers := [2]MCP_Server_Config{
		{name = "enabled", command = "mcp-enabled", enabled = true},
		{name = "disabled", command = "mcp-disabled", enabled = false},
	}
	registry := mcp_registry_from_config(servers[:], context.temp_allocator)
	defer delete(registry.servers)

	assert(len(registry.servers) == 2, "expected configured MCP servers")
	assert(registry.servers[0].status == .Configured, "expected enabled MCP server status")
	assert(registry.servers[1].status == .Disabled, "expected disabled MCP server status")
	_ = t
}

@(test)
test_skill_paths_and_names :: proc(t: ^testing.T) {
	globalDir := global_skill_dir("/home/test", context.temp_allocator)
	defer delete(globalDir, context.temp_allocator)
	projectDir := project_skill_dir("/repo", context.temp_allocator)
	defer delete(projectDir, context.temp_allocator)

	assert(globalDir == "/home/test/.config/mimir/skills", "expected global skills directory")
	assert(projectDir == "/repo/.mimir/skills", "expected project skills directory")
	assert(skill_name_from_path("/repo/.mimir/skills/odin.md") == "odin", "expected name")
	_ = t
}