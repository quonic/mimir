package main

MCP_Server_Config :: struct {
	name:    string,
	command: string,
	args:    []string,
	url:     string,
	enabled: bool,
}

MCP_Server_Status :: enum int {
	Configured = 0,
	Disabled,
	Unavailable,
}

MCP_Server :: struct {
	config: MCP_Server_Config,
	status: MCP_Server_Status,
}

MCP_Registry :: struct {
	servers: [dynamic]MCP_Server,
}

mcp_registry_from_config :: proc(
	servers: []MCP_Server_Config,
	allocator := context.allocator,
) -> MCP_Registry {
	registry: MCP_Registry
	registry.servers = make([dynamic]MCP_Server, 0, len(servers), allocator)
	for server in servers {
		status := MCP_Server_Status.Configured
		if !server.enabled {
			status = .Disabled
		}
		append(&registry.servers, MCP_Server{config = server, status = status})
	}
	return registry
}
