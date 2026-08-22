package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_build_request_includes_required_meta_fields :: proc(t: ^testing.T) {
	params := json.Object(make(map[string]json.Value, 0, context.allocator))
	request := build_request(1, "tools/list", params, context.allocator)
	defer json.destroy_value(request, context.allocator)

	object, isObject := request.(json.Object)
	assert(isObject, "expected request to encode as an object")
	assert(object["jsonrpc"].(json.String) == "2.0", "expected jsonrpc version 2.0")
	assert(object["method"].(json.String) == "tools/list", "expected method to round-trip")

	requestParams, hasParams := object["params"].(json.Object)
	assert(hasParams, "expected params object")
	meta, hasMeta := requestParams["_meta"].(json.Object)
	assert(hasMeta, "expected _meta object on params")
	protocolVersion, hasVersion := meta["io.modelcontextprotocol/protocolVersion"].(json.String)
	assert(hasVersion, "expected protocol version in _meta")
	assert(string(protocolVersion) == PROTOCOL_VERSION, "expected 2026-07-28 protocol version")
	_, hasCapabilities := meta["io.modelcontextprotocol/clientCapabilities"].(json.Object)
	assert(hasCapabilities, "expected client capabilities in _meta")
}

@(test)
test_build_notification_has_no_id :: proc(t: ^testing.T) {
	params := json.Object(make(map[string]json.Value, 0, context.allocator))
	notification := build_notification("notifications/cancelled", params, context.allocator)
	defer json.destroy_value(notification, context.allocator)

	object, isObject := notification.(json.Object)
	assert(isObject, "expected notification to encode as an object")
	_, hasID := object["id"]
	assert(!hasID, "notifications must not include an id")
}

@(test)
test_build_request_for_version_uses_selected_version :: proc(t: ^testing.T) {
	params := json.Object(make(map[string]json.Value, 0, context.allocator))
	request := build_request_for_version(
		4,
		"server/discover",
		params,
		LEGACY_PROTOCOL_VERSION,
		context.allocator,
	)
	defer json.destroy_value(request, context.allocator)

	object := request.(json.Object)
	requestParams := object["params"].(json.Object)
	meta := requestParams["_meta"].(json.Object)
	version := meta["io.modelcontextprotocol/protocolVersion"].(json.String)
	assert(string(version) == LEGACY_PROTOCOL_VERSION, "expected selected protocol version")
}

@(test)
test_build_request_without_meta_is_legacy_shape :: proc(t: ^testing.T) {
	params := json.Object(make(map[string]json.Value, 0, context.allocator))
	request := build_request_without_meta(5, "tools/list", params, context.allocator)
	defer json.destroy_value(request, context.allocator)

	object := request.(json.Object)
	requestParams := object["params"].(json.Object)
	_, hasMeta := requestParams["_meta"]
	assert(!hasMeta, "legacy requests must not include modern metadata")
}

@(test)
test_build_legacy_initialize_and_initialized :: proc(t: ^testing.T) {
	request := build_legacy_initialize(6, context.allocator)
	defer json.destroy_value(request, context.allocator)
	object := request.(json.Object)
	assert(object["method"].(json.String) == "initialize", "expected initialize method")
	params := object["params"].(json.Object)
	assert(
		params["protocolVersion"].(json.String) == LEGACY_PROTOCOL_VERSION,
		"expected legacy protocol version",
	)
	_, hasCapabilities := params["capabilities"].(json.Object)
	assert(hasCapabilities, "expected legacy capabilities")
	_, hasClientInfo := params["clientInfo"].(json.Object)
	assert(hasClientInfo, "expected legacy client info")

	notification := build_legacy_initialized(context.allocator)
	defer json.destroy_value(notification, context.allocator)
	notificationObject := notification.(json.Object)
	assert(
		notificationObject["method"].(json.String) == "notifications/initialized",
		"expected initialized notification",
	)
	_, hasID := notificationObject["id"]
	assert(!hasID, "initialized must be a notification")
}

@(test)
test_encode_message_round_trips_through_parse_response :: proc(t: ^testing.T) {
	result := json.Object(make(map[string]json.Value, 0, context.allocator))
	result[strings.clone("resultType", context.allocator)] = json.String(
		strings.clone("complete", context.allocator),
	)
	result[strings.clone("tools", context.allocator)] = json.Array(
		make([dynamic]json.Value, 0, context.allocator),
	)

	response := json.Object(make(map[string]json.Value, 0, context.allocator))
	response[strings.clone("jsonrpc", context.allocator)] = json.String(
		strings.clone("2.0", context.allocator),
	)
	response[strings.clone("id", context.allocator)] = json.Integer(1)
	response[strings.clone("result", context.allocator)] = result

	encoded, encodeOK := encode_message(response, context.allocator)
	assert(encodeOK, "expected encode_message to succeed")
	defer delete(encoded, context.allocator)
	json.destroy_value(response, context.allocator)

	parsed, parseOK := parse_response(encoded, context.allocator)
	assert(parseOK, "expected parse_response to succeed")
	defer rpc_response_destroy(&parsed, context.allocator)
	assert(!parsed.isError, "expected a successful result response")
	assert(result_type(parsed.result) == "complete", "expected resultType complete")
}

@(test)
test_parse_response_extracts_error :: proc(t: ^testing.T) {
	raw := `{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version"}}`
	parsed, ok := parse_response(raw, context.allocator)
	assert(ok, "expected parse_response to succeed for an error response")
	defer rpc_response_destroy(&parsed, context.allocator)
	assert(parsed.isError, "expected an error response")
	assert(parsed.error.code == ERROR_UNSUPPORTED_PROTOCOL_VERSION, "expected matching error code")
	assert(
		parsed.error.message == "Unsupported protocol version",
		"expected matching error message",
	)
}

@(test)
test_qualify_and_split_name_round_trip :: proc(t: ^testing.T) {
	qualified := qualify_name("github", "search_issues", context.allocator)
	defer delete(qualified, context.allocator)
	assert(qualified == "github.search_issues", "expected server-prefixed tool name")

	serverName, name, ok := split_qualified_name(qualified)
	assert(ok, "expected split to succeed")
	assert(serverName == "github", "expected server name to round-trip")
	assert(name == "search_issues", "expected tool name to round-trip")
}

@(test)
test_split_qualified_name_rejects_missing_separator :: proc(t: ^testing.T) {
	_, _, ok := split_qualified_name("search_issues")
	assert(!ok, "expected split to fail without a separator")
}
