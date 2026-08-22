package mcp

import "core:testing"

@(test)
test_stdio_transport_routes_interleaved_messages :: proc(t: ^testing.T) {
	transport := Stdio_Transport {
		responses     = make([dynamic]Stdio_Response, 0, 4, context.allocator),
		notifications = make([dynamic]string, 0, 4, context.allocator),
		allocator     = context.allocator,
	}
	defer stdio_transport_clear_messages(&transport)

	assert(
		stdio_transport_route_message(
			&transport,
			`{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}`,
		),
		"expected notification to route",
	)
	assert(
		stdio_transport_route_message(&transport, `{"jsonrpc":"2.0","id":4,"result":{}}`),
		"expected response to route",
	)
	assert(len(transport.notifications) == 1, "expected one queued notification")
	assert(len(transport.responses) == 1, "expected one queued response")
	assert(transport.responses[0].id == 4, "expected response ID")
	response, responseOK := stdio_transport_take_response(&transport, 4)
	assert(
		responseOK && response == `{"jsonrpc":"2.0","id":4,"result":{}}`,
		"expected response dequeue",
	)
	notification, notificationOK := stdio_transport_take_notification(&transport)
	assert(
		notificationOK &&
		notification ==
			`{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}`,
		"expected notification dequeue",
	)
	delete(response, context.allocator)
	delete(notification, context.allocator)
	assert(
		!stdio_transport_route_message(&transport, "not-json"),
		"expected malformed message to reject",
	)
}
