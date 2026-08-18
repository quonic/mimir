package mcp

import "core:encoding/json"
import "core:mem"
import "core:strings"

Transport_Kind :: enum {
	None,
	Stdio,
	Http,
}

// Client is a session-less MCP client bound to one server (stdio subprocess or
// Streamable HTTP endpoint). Per the 2026-07-28 spec there is no connection
// state beyond the transport itself: every RPC carries its own `_meta`.
Client :: struct {
	name:               string,
	kind:               Transport_Kind,
	stdio:              Stdio_Transport,
	http:               Http_Transport,
	nextID:             int,
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
			allocator = allocator,
		},
		true
}

client_init_http :: proc(name: string, url: string, allocator := context.allocator) -> Client {
	return Client {
		name = strings.clone(name, allocator),
		kind = .Http,
		http = http_transport_init(url, allocator),
		allocator = allocator,
	}
}

client_destroy :: proc(client: ^Client) {
	delete(client.name, client.allocator)
	switch client.kind {
	case .Stdio:
		stdio_transport_close(&client.stdio)
	case .Http:
		http_transport_destroy(&client.http, client.allocator)
	case .None:
	}
	client^ = {}
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
	request := build_request(client.nextID, method, params, allocator)
	defer json.destroy_value(request, allocator)

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
		body, _, sendOK := http_transport_send(&client.http, method, mcpName, encoded, allocator)
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

// Calls `server/discover` and caches the server's declared capabilities.
// Must succeed before `client_list_tools`/`client_list_resources`/`client_list_prompts`
// will return anything.
client_discover :: proc(client: ^Client, allocator := context.allocator) -> bool {
	params := json.Object(make(map[string]json.Value, 0, allocator))
	response, ok := client_call(client, "server/discover", "", params, allocator)
	if !ok {
		return false
	}
	defer rpc_response_destroy(&response, allocator)
	if response.isError {
		return false
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
		if text, hasText := object["text"].(json.String); hasText {
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
