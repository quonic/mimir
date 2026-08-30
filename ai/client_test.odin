package ai

import http "../http"
import "core:testing"

test_header_value :: proc(headers: [][2]string, key: string) -> (string, bool) {
	for header in headers {
		if header[0] == key {
			return header[1], true
		}
	}
	return "", false
}

test_request_header_value :: proc(headers: http.Headers, key: string) -> (string, bool) {
	return http.headers_get(headers, key)
}

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
	assert(headers[0][0] == "authorization", "expected Authorization header name")
	assert(headers[0][1] == "Bearer secret", "expected Bearer token Authorization header")
	assert(headers[1][0] == "x-api-key", "expected X-API-Key header name")
	assert(headers[1][1] == "secret", "expected raw API key in X-API-Key header")
	_ = t
}

@(test)
test_append_standard_ai_headers_for_chat :: proc(t: ^testing.T) {
	headers: [dynamic][2]string
	defer delete(headers)

	append_standard_ai_headers(&headers, .OpenAI, .Chat)

	userAgent, hasUserAgent := test_header_value(headers[:], "user-agent")
	assert(hasUserAgent, "expected User-Agent header")
	assert(userAgent == MIMIR_USER_AGENT, "expected Mimir user agent")

	accept, hasAccept := test_header_value(headers[:], "accept")
	assert(hasAccept, "expected Accept header")
	assert(accept == "application/json", "expected JSON accept header")

	requestID, hasRequestID := test_header_value(headers[:], "x-request-id")
	assert(hasRequestID, "expected X-Request-Id header")
	assert(requestID != "", "expected non-empty request ID")

	interactionType, hasInteractionType := test_header_value(headers[:], "x-interaction-type")
	assert(hasInteractionType, "expected X-Interaction-Type header")
	assert(interactionType == "conversation", "expected conversation interaction type")

	intent, hasIntent := test_header_value(headers[:], "openai-intent")
	assert(hasIntent, "expected Openai-Intent header for OpenAI chat")
	assert(intent == "conversation-other", "expected OpenAI conversation intent")
	_ = t
}

@(test)
test_append_standard_ai_headers_for_embedding :: proc(t: ^testing.T) {
	headers: [dynamic][2]string
	defer delete(headers)

	append_standard_ai_headers(&headers, .Ollama, .Embedding)

	interactionType, hasInteractionType := test_header_value(headers[:], "x-interaction-type")
	assert(hasInteractionType, "expected X-Interaction-Type header")
	assert(interactionType == "embedding", "expected embedding interaction type")

	_, hasIntent := test_header_value(headers[:], "openai-intent")
	assert(!hasIntent, "expected no Openai-Intent header for Ollama embedding")
	_ = t
}

@(test)
test_apply_extra_headers_normalizes_keys :: proc(t: ^testing.T) {
	headers: [dynamic][2]string
	defer delete(headers)
	append(&headers, [2]string{"user-agent", "Mimir/test"})
	append(&headers, [2]string{"accept", "application/json"})

	requestHeaders: http.Headers
	http.headers_init(&requestHeaders)
	defer delete(requestHeaders._kv)

	apply_extra_headers(&requestHeaders, headers[:])

	userAgent, hasUserAgent := test_request_header_value(requestHeaders, "user-agent")
	assert(hasUserAgent, "expected normalized user-agent header")
	assert(userAgent == "Mimir/test", "expected user-agent value")
	assert(len(requestHeaders._kv) == 2, "expected only lowercase header keys")

	accept, hasAccept := test_request_header_value(requestHeaders, "accept")
	assert(hasAccept, "expected normalized accept header")
	assert(accept == "application/json", "expected accept value")
	_ = t
}
