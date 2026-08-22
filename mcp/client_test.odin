package mcp

import "core:encoding/json"
import "core:testing"

@(test)
test_client_init_http_and_destroy :: proc(t: ^testing.T) {
	client := client_init_http("github", "https://example.com/mcp", context.allocator)
	defer client_destroy(&client)
	assert(client.kind == .Http, "expected an http-kind client")
	assert(client.name == "github", "expected client name to round-trip")
	assert(!client.discovered, "expected a freshly constructed client to be undiscovered")
}

@(test)
test_list_params_omits_cursor_when_empty :: proc(t: ^testing.T) {
	params := list_params("", context.allocator)
	defer delete(params)
	_, hasCursor := params["cursor"]
	assert(!hasCursor, "expected no cursor key when cursor is empty")
}

@(test)
test_list_params_includes_cloned_cursor :: proc(t: ^testing.T) {
	cursor := "abc"
	params := list_params(cursor, context.allocator)
	defer {
		for key, value in params {
			delete(key, context.allocator)
			if text, ok := value.(json.String); ok {
				delete(string(text), context.allocator)
			}
		}
		delete(params)
	}
	value, hasCursor := params["cursor"]
	assert(hasCursor, "expected a cursor key")
	text, isString := value.(json.String)
	assert(isString, "expected cursor value to be a string")
	assert(string(text) == "abc", "expected cursor value to round-trip")
}

@(test)
test_client_polls_owned_stdio_subscription_event :: proc(t: ^testing.T) {
	client := Client {
		kind = .Stdio,
		allocator = context.allocator,
		stdio = Stdio_Transport {
			responses = make([dynamic]Stdio_Response, 0, 1, context.allocator),
			notifications = make([dynamic]string, 0, 1, context.allocator),
			allocator = context.allocator,
		},
	}
	defer stdio_transport_clear_messages(&client.stdio)
	stdio_transport_route_message(
		&client.stdio,
		`{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":4}}}`,
	)
	event, ok := client_poll_subscription_event(&client, context.allocator)
	assert(ok, "expected subscription event")
	assert(event.kind == .ToolsListChanged, "expected tools list change event")
	assert(event.subscriptionID == 4, "expected subscription ID")
}
