package mcp

import "core:encoding/json"
import "core:mem"
import "core:strings"

Transport_Kind :: enum {
	None,
	Stdio,
	Http,
}

Client :: struct {
	name:               string,
	kind:               Transport_Kind,
	stdio:              Stdio_Transport,
	http:               Http_Transport,
	nextID:             int,
	protocolEra:        Protocol_Era,
	protocolVersion:    string,
	discovered:         bool,
	toolsSupported:     bool,
	resourcesSupported: bool,
	promptsSupported:   bool,
	allocator:          mem.Allocator,
}

client_init_stdio :: proc(
	name: string,
	command: string,
	args: []string,
	allocator := context.allocator,
) -> (
	Client,
	bool,
) {
	stdio, ok := stdio_transport_start(command, args, allocator)
	if !ok {
		return Client{}, false
	}
	return Client {
			name = strings.clone(name, allocator),
			kind = .Stdio,
			stdio = stdio,
			protocolEra = .Unknown,
			allocator = allocator,
		},
		true
}

client_init_http :: proc(name: string, url: string, allocator := context.allocator) -> Client {
	return Client {
		name = strings.clone(name, allocator),
		kind = .Http,
		http = http_transport_init(url, allocator),
		protocolEra = .Unknown,
		allocator = allocator,
	}
}

client_destroy :: proc(client: ^Client) {
	delete(client.name, client.allocator)
	delete(client.protocolVersion, client.allocator)
	switch client.kind {
	case .Stdio:
		stdio_transport_close(&client.stdio)
	case .Http:
		http_transport_destroy(&client.http, client.allocator)
	case .None:
	}
	client^ = {}
}

client_send_value :: proc(
	client: ^Client,
	method: string,
	mcpName: string,
	request: json.Value,
	allocator := context.allocator,
) -> (
	RPC_Response,
	bool,
) {
	encoded, encodeOK := encode_message(request, allocator)
	if !encodeOK {
		return RPC_Response{}, false
	}
	defer delete(encoded, allocator)

	switch client.kind {
	case .Stdio:
		if !stdio_transport_write_line(&client.stdio, encoded) {
			return RPC_Response{}, false
		}
		line, readOK := stdio_transport_read_line(&client.stdio, allocator)
		if !readOK {
			return RPC_Response{}, false
		}
		defer delete(line, allocator)
		return parse_response(line, allocator)
	case .Http:
		version := PROTOCOL_VERSION
		if client.protocolVersion != "" {
			version = client.protocolVersion
		} else if client.kind == .Http && client.http.protocolVersion != "" {
			version = client.http.protocolVersion
		}
		body, _, sendOK := http_transport_send(
			&client.http,
			method,
			mcpName,
			encoded,
			version,
			allocator,
		)
		if !sendOK {
			return RPC_Response{}, false
		}
		defer delete(body, allocator)
		return parse_response(body, allocator)
	case .None:
		return RPC_Response{}, false
	}
	return RPC_Response{}, false
}

// Sends a JSON-RPC request and waits for its response. `mcpName` is used only
// by the HTTP transport (`Mcp-Name` header); stdio ignores it. `params` is
// consumed (ownership transferred, matching `build_request`).
client_call :: proc(
	client: ^Client,
	method: string,
	mcpName: string,
	params: json.Object,
	allocator := context.allocator,
) -> (
	RPC_Response,
	bool,
) {
	client.nextID += 1
	request: json.Value
	if client.protocolEra == .Legacy {
		request = build_request_without_meta(client.nextID, method, params, allocator)
	} else {
		version := PROTOCOL_VERSION
		if client.protocolVersion != "" {
			version = client.protocolVersion
		}
		request = build_request_for_version(client.nextID, method, params, version, allocator)
	}
	defer json.destroy_value(request, allocator)
	return client_send_value(client, method, mcpName, request, allocator)
}

client_initialize_legacy :: proc(client: ^Client, allocator := context.allocator) -> bool {
	if client.kind == .Http {
		delete(client.http.protocolVersion, client.allocator)
		client.http.protocolVersion = strings.clone(LEGACY_PROTOCOL_VERSION, client.allocator)
	}
	client.nextID += 1
	request := build_legacy_initialize(client.nextID, allocator)
	response, ok := client_send_value(client, "initialize", "", request, allocator)
	json.destroy_value(request, allocator)
	if !ok {
		return false
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		return false
	}
	version, hasVersion := response.result["protocolVersion"].(json.String)
	if !hasVersion || string(version) != LEGACY_PROTOCOL_VERSION {
		return false
	}
	client.protocolEra = .Legacy
	delete(client.protocolVersion, client.allocator)
	client.protocolVersion = strings.clone(string(version), client.allocator)
	if client.kind == .Http {
		delete(client.http.protocolVersion, client.allocator)
		client.http.protocolVersion = strings.clone(string(version), client.allocator)
	}
	client.toolsSupported = false
	client.resourcesSupported = false
	client.promptsSupported = false
	if capabilities, hasCapabilities := response.result["capabilities"].(json.Object);
	   hasCapabilities {
		_, client.toolsSupported = capabilities["tools"].(json.Object)
		_, client.resourcesSupported = capabilities["resources"].(json.Object)
		_, client.promptsSupported = capabilities["prompts"].(json.Object)
	}
	client.discovered = true

	notification := build_legacy_initialized(allocator)
	encoded, encodeOK := encode_message(notification, allocator)
	json.destroy_value(notification, allocator)
	if !encodeOK {
		return false
	}
	defer delete(encoded, allocator)
	if client.kind == .Stdio {
		return stdio_transport_write_line(&client.stdio, encoded)
	}
	if client.kind == .Http {
		body, status, sendOK := http_transport_send(
			&client.http,
			"notifications/initialized",
			"",
			encoded,
			client.protocolVersion,
			allocator,
		)
		if sendOK {
			delete(body, allocator)
			return status == 202 || status == 200
		}
	}
	return false
}

// Calls `server/discover` and caches the server's declared capabilities.
// Must succeed before `client_list_tools`/`client_list_resources`/`client_list_prompts`
// will return anything.
client_discover :: proc(client: ^Client, allocator := context.allocator) -> bool {
	if client.protocolEra == .Legacy {
		return client_initialize_legacy(client, allocator)
	}
	params := json.Object(make(map[string]json.Value, 0, allocator))
	client.nextID += 1
	probe := build_request_for_version(
		client.nextID,
		"server/discover",
		params,
		PROTOCOL_VERSION,
		allocator,
	)
	response, ok := client_send_value(client, "server/discover", "", probe, allocator)
	json.destroy_value(probe, allocator)
	if !ok {
		return client_initialize_legacy(client, allocator)
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		if response.error.code == ERROR_UNSUPPORTED_PROTOCOL_VERSION {
			version, versionOK := select_protocol_version(response.error.data, allocator)
			if !versionOK {
				return false
			}
			rpc_response_destroy(&response, allocator)
			client.protocolEra = .Modern
			client.protocolVersion = version
			if client.kind == .Http {
				delete(client.http.protocolVersion, client.allocator)
				client.http.protocolVersion = strings.clone(string(version), client.allocator)
			}
			params = json.Object(make(map[string]json.Value, 0, allocator))
			client.nextID += 1
			retry := build_request_for_version(
				client.nextID,
				"server/discover",
				params,
				client.protocolVersion,
				allocator,
			)
			response, ok = client_send_value(client, "server/discover", "", retry, allocator)
			json.destroy_value(retry, allocator)
			if !ok || response.isError {
				if ok {
					rpc_response_destroy(&response, allocator)
				}
				return false
			}
		} else {
			rpc_response_destroy(&response, allocator)
			return client_initialize_legacy(client, allocator)
		}
	} else {
		client.protocolEra = .Modern
		version := PROTOCOL_VERSION
		selectedVersion := ""
		if supported, hasSupported := response.result["supportedVersions"]; hasSupported {
			selected, selectedOK := select_protocol_version(supported, allocator)
			if !selectedOK {
				return false
			}
			version = selected
			selectedVersion = selected
		}
		delete(client.protocolVersion, client.allocator)
		client.protocolVersion = strings.clone(version, client.allocator)
		delete(selectedVersion, allocator)
	}

	client.toolsSupported = false
	client.resourcesSupported = false
	client.promptsSupported = false
	if capabilities, hasCapabilities := response.result["capabilities"].(json.Object);
	   hasCapabilities {
		_, client.toolsSupported = capabilities["tools"].(json.Object)
		_, client.resourcesSupported = capabilities["resources"].(json.Object)
		_, client.promptsSupported = capabilities["prompts"].(json.Object)
	}
	client.discovered = true
	return true
}

list_params :: proc(cursor: string, allocator := context.allocator) -> json.Object {
	params := json.Object(make(map[string]json.Value, 1, allocator))
	if cursor != "" {
		object_set(&params, "cursor", json.String(strings.clone(cursor, allocator)), allocator)
	}
	return params
}

client_list_tools :: proc(client: ^Client, allocator := context.allocator) -> [dynamic]Tool {
	tools := make([dynamic]Tool, 0, 0, allocator)
	if !client.toolsSupported {
		return tools
	}
	cursor := ""
	for {
		params := list_params(cursor, allocator)
		if cursor != "" {
			delete(cursor, allocator)
		}
		response, ok := client_call(client, "tools/list", "", params, allocator)
		if !ok {
			return tools
		}
		page := parse_tools(response.result, allocator)
		for tool in page {
			append(&tools, tool)
		}
		delete(page)
		cursor = next_cursor(response.result, allocator)
		rpc_response_destroy(&response, allocator)
		if cursor == "" {
			break
		}
	}
	return tools
}

client_list_resources :: proc(
	client: ^Client,
	allocator := context.allocator,
) -> [dynamic]Resource {
	resources := make([dynamic]Resource, 0, 0, allocator)
	if !client.resourcesSupported {
		return resources
	}
	cursor := ""
	for {
		params := list_params(cursor, allocator)
		if cursor != "" {
			delete(cursor, allocator)
		}
		response, ok := client_call(client, "resources/list", "", params, allocator)
		if !ok {
			return resources
		}
		page := parse_resources(response.result, allocator)
		for resource in page {
			append(&resources, resource)
		}
		delete(page)
		cursor = next_cursor(response.result, allocator)
		rpc_response_destroy(&response, allocator)
		if cursor == "" {
			break
		}
	}
	return resources
}

client_list_prompts :: proc(client: ^Client, allocator := context.allocator) -> [dynamic]Prompt {
	prompts := make([dynamic]Prompt, 0, 0, allocator)
	if !client.promptsSupported {
		return prompts
	}
	cursor := ""
	for {
		params := list_params(cursor, allocator)
		if cursor != "" {
			delete(cursor, allocator)
		}
		response, ok := client_call(client, "prompts/list", "", params, allocator)
		if !ok {
			return prompts
		}
		page := parse_prompts(response.result, allocator)
		for prompt in page {
			append(&prompts, prompt)
		}
		delete(page)
		cursor = next_cursor(response.result, allocator)
		rpc_response_destroy(&response, allocator)
		if cursor == "" {
			break
		}
	}
	return prompts
}

// Calls a tool by its unqualified (server-local) name with a raw JSON
// arguments object (or "" for no arguments). Returns the rendered text
// content and whether the call is a tool execution error (per the spec's
// `isError` field) or a protocol/transport failure (`ok == false`).
client_call_tool :: proc(
	client: ^Client,
	toolName: string,
	argumentsJSON: string,
	allocator := context.allocator,
) -> (
	text: string,
	isError: bool,
	ok: bool,
) {
	params := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(&params, "name", json.String(strings.clone(toolName, allocator)), allocator)

	argumentsValue: json.Value = json.Object(make(map[string]json.Value, 0, allocator))
	if argumentsJSON != "" {
		if parsed, parseErr := json.parse_string(
			argumentsJSON,
			parse_integers = true,
			allocator = allocator,
		); parseErr == .None {
			if _, isObject := parsed.(json.Object); isObject {
				json.destroy_value(argumentsValue, allocator)
				argumentsValue = parsed
			} else {
				json.destroy_value(parsed, allocator)
			}
		}
	}
	object_set(&params, "arguments", argumentsValue, allocator)

	response, callOK := client_call(client, "tools/call", toolName, params, allocator)
	if !callOK {
		return "", true, false
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		message := response.error.message
		if message == "" {
			message = "MCP tool call failed"
		}
		return strings.clone(message, allocator), true, true
	}
	return render_content_text(response.result, allocator), result_is_error(response.result), true
}

// Reads a resource by URI. Same error-reporting shape as `client_call_tool`.
client_read_resource :: proc(
	client: ^Client,
	uri: string,
	allocator := context.allocator,
) -> (
	text: string,
	ok: bool,
) {
	params := json.Object(make(map[string]json.Value, 1, allocator))
	object_set(&params, "uri", json.String(strings.clone(uri, allocator)), allocator)

	response, callOK := client_call(client, "resources/read", uri, params, allocator)
	if !callOK {
		return "", false
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		message := response.error.message
		if message == "" {
			message = "MCP resource read failed"
		}
		return strings.clone(message, allocator), false
	}

	contentsArray, hasContents := response.result["contents"].(json.Array)
	if !hasContents {
		return strings.clone("", allocator), true
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for entry, index in contentsArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		if index > 0 {
			strings.write_byte(&builder, '\n')
		}
		hasText: bool
		if text, hasText = object["text"].(json.String); hasText {
			strings.write_string(&builder, string(text))
		} else {
			strings.write_string(&builder, "[binary resource content omitted]")
		}
	}
	return strings.to_string(builder), true
}

// Resolves a prompt by name and arguments (raw JSON object, or "" for none)
// into its rendered message text.
client_get_prompt :: proc(
	client: ^Client,
	promptName: string,
	argumentsJSON: string,
	allocator := context.allocator,
) -> (
	text: string,
	ok: bool,
) {
	params := json.Object(make(map[string]json.Value, 2, allocator))
	object_set(&params, "name", json.String(strings.clone(promptName, allocator)), allocator)
	if argumentsJSON != "" {
		if parsed, parseErr := json.parse_string(
			argumentsJSON,
			parse_integers = true,
			allocator = allocator,
		); parseErr == .None {
			if _, isObject := parsed.(json.Object); isObject {
				object_set(&params, "arguments", parsed, allocator)
			} else {
				json.destroy_value(parsed, allocator)
			}
		}
	}

	response, callOK := client_call(client, "prompts/get", promptName, params, allocator)
	if !callOK {
		return "", false
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		message := response.error.message
		if message == "" {
			message = "MCP prompt resolution failed"
		}
		return strings.clone(message, allocator), false
	}

	messagesArray, hasMessages := response.result["messages"].(json.Array)
	if !hasMessages {
		return strings.clone("", allocator), true
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for entry, index in messagesArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		content, hasContent := object["content"].(json.Object)
		if !hasContent {
			continue
		}
		if index > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, json_string_field(content, "text"))
	}
	return strings.to_string(builder), true
}
