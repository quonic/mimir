package mcp

import "core:strings"
import "core:testing"

import "../settings"

@(test)
test_client_reset_protocol_clears_legacy_session :: proc(t: ^testing.T) {
	client := client_init_http("legacy", "https://example.com:8443/mcp", context.allocator)
	defer client_destroy(&client)

	client.protocolEra = .Legacy
	client.protocolVersion = strings.clone(LEGACY_PROTOCOL_VERSION, context.allocator)
	client.discovered = true
	client.http.sessionID = strings.clone("session-1", context.allocator)

	client_reset_protocol(&client)

	assert(client.protocolEra == .Unknown, "expected protocol era to reset")
	assert(client.protocolVersion == "", "expected client protocol version to reset")
	assert(!client.discovered, "expected discovery state to reset")
	assert(client.http.sessionID == "", "expected HTTP session ID to reset")
	assert(
		client.http.protocolVersion == PROTOCOL_VERSION,
		"expected HTTP transport to reset to modern probing",
	)
}

@(test)
test_manager_invalidates_http_origin_cache :: proc(t: ^testing.T) {
	manager := manager_init(context.allocator)
	defer manager_destroy(&manager)
	client := client_init_http("legacy", "https://example.com:8443/mcp", context.allocator)
	defer client_destroy(&client)

	origin := strings.clone(client.http.origin, context.allocator)
	manager.cache[origin] = Era_Cache_Entry {
		era     = .Legacy,
		version = strings.clone(LEGACY_PROTOCOL_VERSION, context.allocator),
	}

	manager_invalidate_cache(&manager, &client)

	_, cached := manager.cache[client.http.origin]
	assert(!cached, "expected cached HTTP era to be removed")
}

@(test)
test_manager_load_registry_reuses_http_origin_cache :: proc(t: ^testing.T) {
	manager := manager_init(context.allocator)
	defer manager_destroy(&manager)

	origin := "https://example.com:8443"
	manager.cache[strings.clone(origin, context.allocator)] = Era_Cache_Entry {
		era     = .Legacy,
		version = strings.clone(LEGACY_PROTOCOL_VERSION, context.allocator),
	}

	config := settings.MCP_Server_Config {
		name    = "legacy",
		url     = "https://example.com:8443/mcp",
		enabled = true,
	}
	registry := settings.mcp_registry_from_config(
		[]settings.MCP_Server_Config{config},
		context.allocator,
	)
	defer delete(registry.servers)
	manager_load_registry(&manager, registry)

	client, found := manager_get(&manager, "legacy")
	assert(found, "expected cached HTTP client to load")
	assert(client.protocolEra == .Legacy, "expected cached legacy era")
	assert(client.protocolVersion == LEGACY_PROTOCOL_VERSION, "expected cached version")
}

@(test)
test_manager_reprobe_clears_cached_session_before_discovery :: proc(t: ^testing.T) {
	manager := manager_init(context.allocator)
	defer manager_destroy(&manager)
	client := client_init_http("legacy", "https://example.com/mcp", context.allocator)
	defer client_destroy(&client)

	client.protocolEra = .Legacy
	client.protocolVersion = strings.clone(LEGACY_PROTOCOL_VERSION, context.allocator)
	client.http.sessionID = strings.clone("expired", context.allocator)
	client.discovered = true

	manager.cache[strings.clone(client.http.origin, context.allocator)] = Era_Cache_Entry {
		era     = .Legacy,
		version = strings.clone(LEGACY_PROTOCOL_VERSION, context.allocator),
	}
	manager_invalidate_cache(&manager, &client)
	client_reset_protocol(&client)

	assert(!client.discovered, "expected failed session to require rediscovery")
	assert(client.http.sessionID == "", "expected failed session ID to be cleared")
	_, cached := manager.cache[client.http.origin]
	assert(!cached, "expected failed era assumption to be evicted")
}

@(test)
test_manager_poll_subscription_events_marks_tools_dirty :: proc(t: ^testing.T) {
	manager := manager_init(context.allocator)
	defer manager_destroy(&manager)
	client := new(Client, context.allocator)
	client^ = Client {
		kind = .Stdio,
		subscriptionActive = true,
		subscriptionID = 4,
		allocator = context.allocator,
		stdio = Stdio_Transport {
			responses = make([dynamic]Stdio_Response, 0, 1, context.allocator),
			notifications = make([dynamic]string, 0, 1, context.allocator),
			allocator = context.allocator,
		},
	}
	manager.clients[strings.clone("server", context.allocator)] = client
	stdio_transport_route_message(
		&client.stdio,
		`{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":4}}}`,
	)

	assert(
		manager_poll_subscription_events(&manager, context.allocator),
		"expected catalog change",
	)
	assert(manager.toolsDirty, "expected tools catalog to become dirty")
}
