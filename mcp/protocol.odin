// Package mcp implements a Model Context Protocol client for the modern,
// stateless 2026-07-28 revision of the spec (no initialize handshake; every
// request carries its protocol version and capabilities inline).
package mcp

import "core:encoding/json"
import "core:strings"

PROTOCOL_VERSION :: "2026-07-28"

CLIENT_NAME :: "mimir"
CLIENT_VERSION :: "0.1.0"

// MCP error codes, per https://modelcontextprotocol.io/specification/2026-07-28/basic#error-codes
ERROR_PARSE_ERROR :: -32700
ERROR_INVALID_REQUEST :: -32600
ERROR_METHOD_NOT_FOUND :: -32601
ERROR_INVALID_PARAMS :: -32602
ERROR_INTERNAL_ERROR :: -32603
ERROR_HEADER_MISMATCH :: -32020
ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY :: -32021
ERROR_UNSUPPORTED_PROTOCOL_VERSION :: -32022

RPC_Error :: struct {
	code:    int,
	message: string,
	hasData: bool,
	data:    json.Value,
}

// A decoded JSON-RPC response. `raw` owns all values reachable from `result`/`error`
// and must be freed with `rpc_response_destroy`.
RPC_Response :: struct {
	isError: bool,
	error:   RPC_Error,
	result:  json.Object,
	raw:     json.Value,
}

rpc_response_destroy :: proc(response: ^RPC_Response, allocator := context.allocator) {
	if response.raw != nil {
		json.destroy_value(response.raw, allocator)
	}
	response^ = {}
}

// Inserts `value` under a heap-cloned copy of `key`. All strings and object
// keys reachable from values this package builds are heap-allocated so that
// `json.destroy_value` can safely free the whole tree.
object_set :: proc(
	object: ^json.Object,
	key: string,
	value: json.Value,
	allocator := context.allocator,
) {
	clonedKey := strings.clone(key, allocator)
	object[clonedKey] = value
}

// Builds the required `_meta` object for a request per the spec's per-request
// protocol fields (protocolVersion + clientCapabilities are required; clientInfo
// is recommended).
build_meta :: proc(allocator := context.allocator) -> json.Object {
	meta := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(
		&meta,
		"io.modelcontextprotocol/protocolVersion",
		json.String(strings.clone(PROTOCOL_VERSION, allocator)),
		allocator,
	)
	object_set(
		&meta,
		"io.modelcontextprotocol/clientCapabilities",
		json.Object(make(map[string]json.Value, 0, allocator)),
		allocator,
	)
	clientInfo := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(&clientInfo, "name", json.String(strings.clone(CLIENT_NAME, allocator)), allocator)
	object_set(
		&clientInfo,
		"version",
		json.String(strings.clone(CLIENT_VERSION, allocator)),
		allocator,
	)
	object_set(&meta, "io.modelcontextprotocol/clientInfo", clientInfo, allocator)
	return meta
}

// Builds a JSON-RPC request envelope: {jsonrpc, id, method, params}. `params`
// is consumed (its `_meta` key is set/overwritten) and takes ownership.
build_request :: proc(
	id: int,
	method: string,
	params: json.Object,
	allocator := context.allocator,
) -> json.Value {
	params := params
	object_set(&params, "_meta", build_meta(allocator), allocator)

	request := json.Object(make(map[string]json.Value, 4, allocator))
	object_set(&request, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(&request, "id", json.Integer(i64(id)), allocator)
	object_set(&request, "method", json.String(strings.clone(method, allocator)), allocator)
	object_set(&request, "params", params, allocator)
	return request
}

// Builds a JSON-RPC notification envelope: {jsonrpc, method, params}.
build_notification :: proc(
	method: string,
	params: json.Object,
	allocator := context.allocator,
) -> json.Value {
	params := params
	object_set(&params, "_meta", build_meta(allocator), allocator)

	notification := json.Object(make(map[string]json.Value, 3, allocator))
	object_set(&notification, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(&notification, "method", json.String(strings.clone(method, allocator)), allocator)
	object_set(&notification, "params", params, allocator)
	return notification
}

// Encodes a JSON-RPC message value to a wire string. Caller keeps ownership of `value`.
encode_message :: proc(value: json.Value, allocator := context.allocator) -> (string, bool) {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Parses a single JSON-RPC response line/body into an `RPC_Response`.
// On success, the caller owns `response.raw` and must call `rpc_response_destroy`.
parse_response :: proc(raw: string, allocator := context.allocator) -> (RPC_Response, bool) {
	value, err := json.parse_string(raw, parse_integers = true, allocator = allocator)
	if err != .None {
		return RPC_Response{}, false
	}
	obj, isObject := value.(json.Object)
	if !isObject {
		json.destroy_value(value, allocator)
		return RPC_Response{}, false
	}

	response: RPC_Response
	response.raw = value

	if errorValue, hasError := obj["error"]; hasError {
		errorObject, errorOK := errorValue.(json.Object)
		if !errorOK {
			rpc_response_destroy(&response, allocator)
			return RPC_Response{}, false
		}
		response.isError = true
		if code, codeOK := errorObject["code"].(json.Integer); codeOK {
			response.error.code = int(code)
		}
		if message, messageOK := errorObject["message"].(json.String); messageOK {
			response.error.message = string(message)
		}
		if data, hasData := errorObject["data"]; hasData {
			response.error.data = data
			response.error.hasData = true
		}
		return response, true
	}

	if resultValue, hasResult := obj["result"]; hasResult {
		resultObject, resultOK := resultValue.(json.Object)
		if !resultOK {
			rpc_response_destroy(&response, allocator)
			return RPC_Response{}, false
		}
		response.result = resultObject
		return response, true
	}

	rpc_response_destroy(&response, allocator)
	return RPC_Response{}, false
}

// Reads the `resultType` field of a result object, defaulting to "complete"
// when absent (as required for backward compatibility, and true of every
// response this client produces requests for).
result_type :: proc(result: json.Object) -> string {
	if value, ok := result["resultType"].(json.String); ok {
		return string(value)
	}
	return "complete"
}

// Fully-qualified tool/prompt/resource name disambiguation: `{serverName}.{name}`.
qualify_name :: proc(serverName: string, name: string, allocator := context.allocator) -> string {
	return strings.concatenate({serverName, ".", name}, allocator)
}

// Splits a qualified `{serverName}.{name}` into its parts. Returns ok=false if
// there is no separator.
split_qualified_name :: proc(qualified: string) -> (serverName: string, name: string, ok: bool) {
	dot := strings.index(qualified, ".")
	if dot <= 0 || dot >= len(qualified) - 1 {
		return "", "", false
	}
	return qualified[:dot], qualified[dot + 1:], true
}
