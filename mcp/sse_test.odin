package mcp

import "core:testing"

@(test)
test_sse_extract_final_response_skips_progress_notifications :: proc(t: ^testing.T) {
	body :=
		"data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" +
		"data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\"}}\n\n"
	final, ok := sse_extract_final_response(body, context.allocator)
	assert(ok, "expected to find a final response event")
	defer delete(final, context.allocator)
	assert(
		final == `{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}`,
		"expected the result event, not the progress notification",
	)
}

@(test)
test_sse_extract_final_response_ignores_comment_lines :: proc(t: ^testing.T) {
	body := ": keep-alive\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad\"}}\n\n"
	final, ok := sse_extract_final_response(body, context.allocator)
	assert(ok, "expected to find the error response event")
	defer delete(final, context.allocator)
	assert(
		final == `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad"}}`,
		"expected the error event text to be extracted verbatim",
	)
}

@(test)
test_sse_extract_final_response_supports_multiline_data :: proc(t: ^testing.T) {
	body := "data: {\"jsonrpc\":\"2.0\",\n" + "data: \"id\":1,\"result\":{}}\n\n"
	final, ok := sse_extract_final_response(body, context.allocator)
	assert(ok, "expected multi-line data fields to be joined with newlines")
	defer delete(final, context.allocator)
	assert(final == "{\"jsonrpc\":\"2.0\",\n\"id\":1,\"result\":{}}", "expected joined data lines")
}

@(test)
test_sse_extract_final_response_returns_false_when_absent :: proc(t: ^testing.T) {
	body := "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n\n"
	final, ok := sse_extract_final_response(body, context.allocator)
	defer if ok {
		delete(final, context.allocator)
	}
	assert(!ok, "expected no final response when only notifications are present")
}
