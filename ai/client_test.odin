package ai

import "core:testing"

@(test)
test_append_api_key_auth_headers_with_empty_key :: proc(t: ^testing.T) {
	headers: [dynamic][2]string
	defer delete(headers)

	append_api_key_auth_headers(&headers, "")
	assert(len(headers) == 0, "expected no auth headers when API key is empty")
	_ = t
}

@(test)
test_append_api_key_auth_headers_with_key :: proc(t: ^testing.T) {
	headers: [dynamic][2]string
	defer delete(headers)

	append_api_key_auth_headers(&headers, "secret")

	assert(len(headers) == 2, "expected Authorization and X-API-Key headers")
	assert(headers[0][0] == "Authorization", "expected Authorization header name")
	assert(headers[0][1] == "Bearer secret", "expected Bearer token Authorization header")
	assert(headers[1][0] == "X-API-Key", "expected X-API-Key header name")
	assert(headers[1][1] == "secret", "expected raw API key in X-API-Key header")
	_ = t
}
