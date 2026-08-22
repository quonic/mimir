package mcp

import "core:mem"
import "core:strings"

import "../settings"

// Manager owns one live `Client` per enabled MCP server configured in
// `settings.MCP_Registry`, keyed by server name. Servers are connected lazily:
// a stdio subprocess is spawned (or an HTTP client constructed) when the
// manager is loaded, but `server/discover` only runs on first use of a given
// server (`manager_ensure_discovered`).
Manager :: struct {
	clients:   map[string]^Client,
	cache:     map[string]Era_Cache_Entry,
	allocator: mem.Allocator,
}

Era_Cache_Entry :: struct {
	era:     Protocol_Era,
	version: string,
}

manager_init :: proc(allocator := context.allocator) -> Manager {
	return Manager {
		clients = make(map[string]^Client, 0, allocator),
		cache = make(map[string]Era_Cache_Entry, 0, allocator),
		allocator = allocator,
	}
}

manager_destroy :: proc(manager: ^Manager) {
	for name, clientPtr in manager.clients {
		client_destroy(clientPtr)
		free(clientPtr, manager.allocator)
		delete(name, manager.allocator)
	}
	delete(manager.clients)
	for origin, entry in manager.cache {
		delete(origin, manager.allocator)
		delete(entry.version, manager.allocator)
	}
	delete(manager.cache)
	manager^ = {}
}

client_from_config :: proc(
	config: settings.MCP_Server_Config,
	allocator := context.allocator,
) -> (
	Client,
	bool,
) {
	if config.command != "" {
		return client_init_stdio(config.name, config.command, config.args, allocator)
	}
	if config.url != "" {
		return client_init_http(config.name, config.url, allocator), true
	}
	return Client{}, false
}

// Connects a client for every enabled, not-yet-loaded server in `registry`.
// Existing clients for servers already present are left untouched.
manager_load_registry :: proc(
	manager: ^Manager,
	registry: settings.MCP_Registry,
	allocator := context.allocator,
) {
	for server in registry.servers {
		if server.status == .Disabled {
			continue
		}
		if server.config.name in manager.clients {
			continue
		}
		client, ok := client_from_config(server.config, allocator)
		if !ok {
			continue
		}
		if client.kind == .Http {
			if entry, cached := manager.cache[client.http.origin]; cached {
				client.protocolEra = entry.era
				client.protocolVersion = strings.clone(entry.version, allocator)
				if entry.era == .Modern {
					delete(client.http.protocolVersion, allocator)
					client.http.protocolVersion = strings.clone(entry.version, allocator)
				}
			}
		}
		clientPtr := new(Client, allocator)
		clientPtr^ = client
		manager.clients[strings.clone(server.config.name, allocator)] = clientPtr
	}
}

manager_get :: proc(manager: ^Manager, name: string) -> (^Client, bool) {
	clientPtr, ok := manager.clients[name]
	return clientPtr, ok
}

// Returns the client for `name`, running `server/discover` on first use.
// ok=false means the server is unknown/disabled or discovery failed.
manager_ensure_discovered :: proc(
	manager: ^Manager,
	name: string,
	allocator := context.allocator,
) -> (
	^Client,
	bool,
) {
	clientPtr, exists := manager_get(manager, name)
	if !exists {
		return nil, false
	}
	if !clientPtr.discovered {
		if !client_discover(clientPtr, allocator) {
			return clientPtr, false
		}
		if clientPtr.kind == .Http && clientPtr.protocolVersion != "" {
			origin := clientPtr.http.origin
			if old, exists := manager.cache[origin]; exists {
				delete(old.version, manager.allocator)
			} else {
				origin = strings.clone(origin, manager.allocator)
			}
			manager.cache[origin] = Era_Cache_Entry {
				era     = clientPtr.protocolEra,
				version = strings.clone(clientPtr.protocolVersion, manager.allocator),
			}
		}
	}
	return clientPtr, true
}

// A tool paired with the server it came from, for building server-prefixed
// (`{server}.{tool}`) definitions in the caller's tool-list format.
Qualified_Tool :: struct {
	serverName: string,
	tool:       Tool,
}

qualified_tools_destroy :: proc(tools: [dynamic]Qualified_Tool, allocator := context.allocator) {
	for &entry in tools {
		delete(entry.serverName, allocator)
		tool_destroy(&entry.tool, allocator)
	}
	delete(tools)
}

// Lists tools across every discoverable, tools-capable server. Servers that
// fail to discover are skipped (not treated as a fatal error for the others).
manager_all_tools :: proc(
	manager: ^Manager,
	allocator := context.allocator,
) -> [dynamic]Qualified_Tool {
	all := make([dynamic]Qualified_Tool, 0, 0, allocator)
	for name in manager.clients {
		clientPtr, ok := manager_ensure_discovered(manager, name, allocator)
		if !ok || !clientPtr.toolsSupported {
			continue
		}
		tools := client_list_tools(clientPtr, allocator)
		for tool in tools {
			append(&all, Qualified_Tool{serverName = strings.clone(name, allocator), tool = tool})
		}
		delete(tools)
	}
	return all
}

// A prompt paired with the server it came from.
Qualified_Prompt :: struct {
	serverName: string,
	prompt:     Prompt,
}

qualified_prompts_destroy :: proc(
	prompts: [dynamic]Qualified_Prompt,
	allocator := context.allocator,
) {
	for &entry in prompts {
		delete(entry.serverName, allocator)
		prompt_destroy(&entry.prompt, allocator)
	}
	delete(prompts)
}

// Lists prompts across every discoverable, prompts-capable server.
manager_all_prompts :: proc(
	manager: ^Manager,
	allocator := context.allocator,
) -> [dynamic]Qualified_Prompt {
	all := make([dynamic]Qualified_Prompt, 0, 0, allocator)
	for name in manager.clients {
		clientPtr, ok := manager_ensure_discovered(manager, name, allocator)
		if !ok || !clientPtr.promptsSupported {
			continue
		}
		prompts := client_list_prompts(clientPtr, allocator)
		for prompt in prompts {
			append(
				&all,
				Qualified_Prompt{serverName = strings.clone(name, allocator), prompt = prompt},
			)
		}
		delete(prompts)
	}
	return all
}

// Calls `toolName` on `serverName`, discovering the server first if needed.
manager_call_tool :: proc(
	manager: ^Manager,
	serverName: string,
	toolName: string,
	argumentsJSON: string,
	allocator := context.allocator,
) -> (
	text: string,
	isError: bool,
	ok: bool,
) {
	clientPtr, discovered := manager_ensure_discovered(manager, serverName, allocator)
	if !discovered {
		return strings.clone("MCP server unavailable.", allocator), true, false
	}
	if !clientPtr.toolsSupported {
		return strings.clone("MCP server does not support tools.", allocator), true, false
	}
	return client_call_tool(clientPtr, toolName, argumentsJSON, allocator)
}

// Reads a resource by URI from `serverName`, discovering the server first if needed.
manager_read_resource :: proc(
	manager: ^Manager,
	serverName: string,
	uri: string,
	allocator := context.allocator,
) -> (
	text: string,
	ok: bool,
) {
	clientPtr, discovered := manager_ensure_discovered(manager, serverName, allocator)
	if !discovered {
		return strings.clone("MCP server unavailable.", allocator), false
	}
	if !clientPtr.resourcesSupported {
		return strings.clone("MCP server does not support resources.", allocator), false
	}
	return client_read_resource(clientPtr, uri, allocator)
}

// Resolves a prompt by name from `serverName`, discovering the server first if needed.
manager_get_prompt :: proc(
	manager: ^Manager,
	serverName: string,
	promptName: string,
	argumentsJSON: string,
	allocator := context.allocator,
) -> (
	text: string,
	ok: bool,
) {
	clientPtr, discovered := manager_ensure_discovered(manager, serverName, allocator)
	if !discovered {
		return strings.clone("MCP server unavailable.", allocator), false
	}
	if !clientPtr.promptsSupported {
		return strings.clone("MCP server does not support prompts.", allocator), false
	}
	return client_get_prompt(clientPtr, promptName, argumentsJSON, allocator)
}
