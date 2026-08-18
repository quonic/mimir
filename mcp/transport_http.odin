package mcp

import "core:bytes"
import "core:strings"

import http "../http"
import httpClient "../http/client"

// Http_Transport sends each JSON-RPC message as its own POST to a Streamable
// HTTP MCP endpoint, per
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.
// Sessions, resumable streams, and the GET/DELETE endpoint from earlier
// revisions are not part of this protocol version and are not implemented.
Http_Transport :: struct {
	url: string,
}

http_transport_init :: proc(url: string, allocator := context.allocator) -> Http_Transport {
	return Http_Transport{url = strings.clone(url, allocator)}
}

http_transport_destroy :: proc(t: ^Http_Transport, allocator := context.allocator) {
	delete(t.url, allocator)
	t^ = {}
}

// Sends a single JSON-RPC request body. `mcpName` is the tool/resource/prompt
// name (or empty for methods without one) mirrored into the `Mcp-Name` header
// as required by the spec. Returns the raw response body text (already
// unwrapped from an SSE envelope, if the server used one) and the HTTP status.
http_transport_send :: proc(
	t: ^Http_Transport,
	method: string,
	mcpName: string,
	rawJSON: string,
	allocator := context.allocator,
) -> (
	body: string,
	status: int,
	ok: bool,
) {
	req: httpClient.Request
	httpClient.request_init(&req, .Post, allocator)
	defer httpClient.request_destroy(&req)

	http.headers_set_content_type(&req.headers, http.mime_to_content_type(.Json))
	http.headers_set_unsafe(&req.headers, "Accept", "application/json, text/event-stream")
	http.headers_set_unsafe(&req.headers, "MCP-Protocol-Version", PROTOCOL_VERSION)
	http.headers_set_unsafe(&req.headers, "Mcp-Method", method)
	if mcpName != "" {
		http.headers_set_unsafe(&req.headers, "Mcp-Name", mcpName)
	}
	bytes.buffer_write(&req.body, transmute([]byte)rawJSON)

	res, reqErr := httpClient.request(&req, t.url, allocator)
	if reqErr != nil {
		return "", 0, false
	}
	defer httpClient.response_destroy(&res)
	status = int(res.status)

	responseBody, allocated, bodyErr := httpClient.response_body(&res, -1, allocator)
	if bodyErr != nil {
		return "", status, false
	}
	defer httpClient.body_destroy(responseBody, allocated, allocator)

	plain, isPlain := responseBody.(httpClient.Body_Plain)
	if !isPlain {
		return "", status, false
	}
	rawBody := string(plain)

	contentType, _ := http.headers_get(res.headers, "content-type")
	if strings.contains(contentType, "text/event-stream") {
		final, found := sse_extract_final_response(rawBody, allocator)
		if !found {
			return "", status, false
		}
		return final, status, true
	}

	return strings.clone(rawBody, allocator), status, true
}
