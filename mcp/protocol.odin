// Package mcp implements a Model Context Protocol client for the modern,
// stateless 2026-07-28 revision of the spec (no initialize handshake; every
// request carries its protocol version and capabilities inline).
package mcp

import "core:encoding/json"
import "core:strings"

PROTOCOL_VERSION :: "2026-07-28"
LEGACY_PROTOCOL_VERSION :: "2025-11-25"

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

Protocol_Era :: enum {
	Unknown,
	Modern,
	Legacy,
}

Subscription_Filter :: struct {
	toolsListChanged:      bool,
	promptsListChanged:    bool,
	resourcesListChanged:  bool,
	resourceSubscriptions: [dynamic]string,
}

subscription_filter_destroy :: proc(filter: ^Subscription_Filter, allocator := context.allocator) {
	for uri in filter.resourceSubscriptions {
		delete(uri, allocator)
	}
	delete(filter.resourceSubscriptions)
	filter^ = {}
}

Subscription_Event_Kind :: enum {
	Acknowledged,
	ToolsListChanged,
	ResourcesListChanged,
	PromptsListChanged,
	ResourceUpdated,
	Completed,
}

Subscription_Event :: struct {
	kind:           Subscription_Event_Kind,
	subscriptionID: int,
	resourceURI:    string,
}

subscription_event_destroy :: proc(event: ^Subscription_Event, allocator := context.allocator) {
	delete(event.resourceURI, allocator)
	event^ = {}
}

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
build_meta_for_version :: proc(
	protocolVersion: string,
	allocator := context.allocator,
) -> json.Object {
	meta := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(
		&meta,
		"io.modelcontextprotocol/protocolVersion",
		json.String(strings.clone(protocolVersion, allocator)),
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

build_meta :: proc(allocator := context.allocator) -> json.Object {
	return build_meta_for_version(PROTOCOL_VERSION, allocator)
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

build_request_for_version :: proc(
	id: int,
	method: string,
	params: json.Object,
	protocolVersion: string,
	allocator := context.allocator,
) -> json.Value {
	params := params
	object_set(&params, "_meta", build_meta_for_version(protocolVersion, allocator), allocator)

	request := json.Object(make(map[string]json.Value, 4, allocator))
	object_set(&request, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(&request, "id", json.Integer(i64(id)), allocator)
	object_set(&request, "method", json.String(strings.clone(method, allocator)), allocator)
	object_set(&request, "params", params, allocator)
	return request
}

build_request_without_meta :: proc(
	id: int,
	method: string,
	params: json.Object,
	allocator := context.allocator,
) -> json.Value {
	request := json.Object(make(map[string]json.Value, 4, allocator))
	object_set(&request, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(&request, "id", json.Integer(i64(id)), allocator)
	object_set(&request, "method", json.String(strings.clone(method, allocator)), allocator)
	object_set(&request, "params", params, allocator)
	return request
}

build_subscription_params :: proc(
	filter: Subscription_Filter,
	allocator := context.allocator,
) -> json.Object {
	notifications := json.Object(make(map[string]json.Value, 4, allocator))
	if filter.toolsListChanged {
		object_set(&notifications, "toolsListChanged", json.Boolean(true), allocator)
	}
	if filter.promptsListChanged {
		object_set(&notifications, "promptsListChanged", json.Boolean(true), allocator)
	}
	if filter.resourcesListChanged {
		object_set(&notifications, "resourcesListChanged", json.Boolean(true), allocator)
	}
	if len(filter.resourceSubscriptions) > 0 {
		uris := make([dynamic]json.Value, 0, len(filter.resourceSubscriptions), allocator)
		for uri in filter.resourceSubscriptions {
			append(&uris, json.String(strings.clone(uri, allocator)))
		}
		object_set(&notifications, "resourceSubscriptions", json.Array(uris), allocator)
	}

	params := json.Object(make(map[string]json.Value, 1, allocator))
	object_set(&params, "notifications", notifications, allocator)
	return params
}

build_subscription_request :: proc(
	id: int,
	filter: Subscription_Filter,
	protocolVersion := PROTOCOL_VERSION,
	allocator := context.allocator,
) -> json.Value {
	return build_request_for_version(
		id,
		"subscriptions/listen",
		build_subscription_params(filter, allocator),
		protocolVersion,
		allocator,
	)
}

build_subscription_cancelled :: proc(
	subscriptionID: int,
	allocator := context.allocator,
) -> json.Value {
	meta := json.Object(make(map[string]json.Value, 1, allocator))
	object_set(
		&meta,
		"io.modelcontextprotocol/subscriptionId",
		json.Integer(i64(subscriptionID)),
		allocator,
	)
	params := json.Object(make(map[string]json.Value, 1, allocator))
	object_set(&params, "_meta", meta, allocator)

	notification := json.Object(make(map[string]json.Value, 3, allocator))
	object_set(&notification, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(
		&notification,
		"method",
		json.String(strings.clone("notifications/cancelled", allocator)),
		allocator,
	)
	object_set(&notification, "params", params, allocator)
	return notification
}

build_legacy_initialize :: proc(id: int, allocator := context.allocator) -> json.Value {
	params := json.Object(make(map[string]json.Value, 3, allocator))
	object_set(
		&params,
		"protocolVersion",
		json.String(strings.clone(LEGACY_PROTOCOL_VERSION, allocator)),
		allocator,
	)
	object_set(
		&params,
		"capabilities",
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
	object_set(&params, "clientInfo", clientInfo, allocator)

	request := json.Object(make(map[string]json.Value, 4, allocator))
	object_set(&request, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(&request, "id", json.Integer(i64(id)), allocator)
	object_set(&request, "method", json.String(strings.clone("initialize", allocator)), allocator)
	object_set(&request, "params", params, allocator)
	return request
}

build_legacy_initialized :: proc(allocator := context.allocator) -> json.Value {
	notification := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(&notification, "jsonrpc", json.String(strings.clone("2.0", allocator)), allocator)
	object_set(
		&notification,
		"method",
		json.String(strings.clone("notifications/initialized", allocator)),
		allocator,
	)
	return notification
}

select_protocol_version :: proc(
	supported: json.Value,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	versions, ok := supported.(json.Array)
	if object, isObject := supported.(json.Object); isObject {
		versions, ok = object["supported"].(json.Array)
		if !ok {
			versions, ok = object["supportedVersions"].(json.Array)
		}
	}
	if !ok {
		return "", false
	}
	for versionValue in versions {
		version, isString := versionValue.(json.String)
		if isString && string(version) == PROTOCOL_VERSION {
			return strings.clone(PROTOCOL_VERSION, allocator), true
		}
	}
	return "", false
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

parse_subscription_event :: proc(
	raw: string,
	allocator := context.allocator,
) -> (
	Subscription_Event,
	bool,
) {
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.temp_allocator)
	if err != .None {
		return Subscription_Event{}, false
	}
	defer json.destroy_value(value, context.temp_allocator)
	object, objectOK := value.(json.Object)
	if !objectOK {
		return Subscription_Event{}, false
	}
	method, methodOK := object["method"].(json.String)
	if !methodOK {
		if _, hasResult := object["result"]; hasResult {
			return Subscription_Event{kind = .Completed}, true
		}
		return Subscription_Event{}, false
	}
	params, paramsOK := object["params"].(json.Object)
	if !paramsOK {
		return Subscription_Event{}, false
	}
	meta, metaOK := params["_meta"].(json.Object)
	if !metaOK {
		return Subscription_Event{}, false
	}
	idValue, idOK := meta["io.modelcontextprotocol/subscriptionId"].(json.Integer)
	if !idOK {
		return Subscription_Event{}, false
	}
	event := Subscription_Event {
		subscriptionID = int(idValue),
	}
	switch string(method) {
	case "notifications/subscriptions/acknowledged":
		event.kind = .Acknowledged
	case "notifications/tools/list_changed":
		event.kind = .ToolsListChanged
	case "notifications/resources/list_changed":
		event.kind = .ResourcesListChanged
	case "notifications/prompts/list_changed":
		event.kind = .PromptsListChanged
	case "notifications/resources/updated":
		event.kind = .ResourceUpdated
		uri, uriOK := params["uri"].(json.String)
		if !uriOK {
			return Subscription_Event{}, false
		}
		event.resourceURI = strings.clone(string(uri), allocator)
	case:
		return Subscription_Event{}, false
	}
	return event, true
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
