package mcp

import "core:encoding/json"
import "core:strings"

Tool :: struct {
	name:            string,
	description:     string,
	inputSchemaJSON: string,
}

tool_destroy :: proc(tool: ^Tool, allocator := context.allocator) {
	delete(tool.name, allocator)
	delete(tool.description, allocator)
	delete(tool.inputSchemaJSON, allocator)
	tool^ = {}
}

tools_destroy :: proc(tools: [dynamic]Tool, allocator := context.allocator) {
	for &tool in tools {
		tool_destroy(&tool, allocator)
	}
	delete(tools)
}

Resource :: struct {
	uri:         string,
	name:        string,
	description: string,
	mimeType:    string,
}

resource_destroy :: proc(resource: ^Resource, allocator := context.allocator) {
	delete(resource.uri, allocator)
	delete(resource.name, allocator)
	delete(resource.description, allocator)
	delete(resource.mimeType, allocator)
	resource^ = {}
}

resources_destroy :: proc(resources: [dynamic]Resource, allocator := context.allocator) {
	for &resource in resources {
		resource_destroy(&resource, allocator)
	}
	delete(resources)
}

Prompt :: struct {
	name:        string,
	description: string,
}

prompt_destroy :: proc(prompt: ^Prompt, allocator := context.allocator) {
	delete(prompt.name, allocator)
	delete(prompt.description, allocator)
	prompt^ = {}
}

prompts_destroy :: proc(prompts: [dynamic]Prompt, allocator := context.allocator) {
	for &prompt in prompts {
		prompt_destroy(&prompt, allocator)
	}
	delete(prompts)
}

json_string_field :: proc(object: json.Object, key: string) -> string {
	if value, ok := object[key].(json.String); ok {
		return string(value)
	}
	return ""
}

// Parses the `tools` array of a `tools/list` result. Ignores malformed entries.
parse_tools :: proc(result: json.Object, allocator := context.allocator) -> [dynamic]Tool {
	tools := make([dynamic]Tool, 0, 0, allocator)
	toolsArray, hasTools := result["tools"].(json.Array)
	if !hasTools {
		return tools
	}
	for entry in toolsArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		name := json_string_field(object, "name")
		if name == "" {
			continue
		}
		inputSchemaJSON := ""
		if schema, hasSchema := object["inputSchema"]; hasSchema {
			if encoded, ok := json.marshal(schema, allocator = allocator); ok == nil {
				inputSchemaJSON = string(encoded)
			}
		}
		append(
			&tools,
			Tool {
				name = strings.clone(name, allocator),
				description = strings.clone(json_string_field(object, "description"), allocator),
				inputSchemaJSON = inputSchemaJSON,
			},
		)
	}
	return tools
}

// Parses the `resources` array of a `resources/list` result. Ignores malformed entries.
parse_resources :: proc(result: json.Object, allocator := context.allocator) -> [dynamic]Resource {
	resources := make([dynamic]Resource, 0, 0, allocator)
	resourcesArray, hasResources := result["resources"].(json.Array)
	if !hasResources {
		return resources
	}
	for entry in resourcesArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		uri := json_string_field(object, "uri")
		if uri == "" {
			continue
		}
		append(
			&resources,
			Resource {
				uri = strings.clone(uri, allocator),
				name = strings.clone(json_string_field(object, "name"), allocator),
				description = strings.clone(json_string_field(object, "description"), allocator),
				mimeType = strings.clone(json_string_field(object, "mimeType"), allocator),
			},
		)
	}
	return resources
}

// Parses the `prompts` array of a `prompts/list` result. Ignores malformed entries.
parse_prompts :: proc(result: json.Object, allocator := context.allocator) -> [dynamic]Prompt {
	prompts := make([dynamic]Prompt, 0, 0, allocator)
	promptsArray, hasPrompts := result["prompts"].(json.Array)
	if !hasPrompts {
		return prompts
	}
	for entry in promptsArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		name := json_string_field(object, "name")
		if name == "" {
			continue
		}
		append(
			&prompts,
			Prompt {
				name = strings.clone(name, allocator),
				description = strings.clone(json_string_field(object, "description"), allocator),
			},
		)
	}
	return prompts
}

// Reads the `nextCursor` field shared by paginated list results, if present.
next_cursor :: proc(result: json.Object, allocator := context.allocator) -> string {
	if value, ok := result["nextCursor"].(json.String); ok {
		return strings.clone(string(value), allocator)
	}
	return ""
}

// Renders a `tools/call`/`resources/read` result's `content` blocks as a single
// text string for feeding back into the model. Non-text blocks (image, audio,
// resource) are replaced with a short placeholder; multi-modal tool results are
// not rendered in this pass.
render_content_text :: proc(result: json.Object, allocator := context.allocator) -> string {
	contentArray, hasContent := result["content"].(json.Array)
	if !hasContent {
		return strings.clone("", allocator)
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for entry, index in contentArray {
		object, isObject := entry.(json.Object)
		if !isObject {
			continue
		}
		if index > 0 {
			strings.write_byte(&builder, '\n')
		}
		blockType := json_string_field(object, "type")
		switch blockType {
		case "text":
			strings.write_string(&builder, json_string_field(object, "text"))
		case "resource_link":
			strings.write_string(&builder, "[resource link: ")
			strings.write_string(&builder, json_string_field(object, "uri"))
			strings.write_byte(&builder, ']')
		case "resource":
			if resourceObject, ok := object["resource"].(json.Object); ok {
				if text := json_string_field(resourceObject, "text"); text != "" {
					strings.write_string(&builder, text)
				} else {
					strings.write_string(&builder, "[embedded resource: ")
					strings.write_string(&builder, json_string_field(resourceObject, "uri"))
					strings.write_byte(&builder, ']')
				}
			}
		case:
			strings.write_string(&builder, "[non-text content omitted: ")
			strings.write_string(&builder, blockType)
			strings.write_byte(&builder, ']')
		}
	}
	return strings.to_string(builder)
}

// Reports whether a `tools/call` result is an error per the `isError` field.
result_is_error :: proc(result: json.Object) -> bool {
	value, ok := result["isError"].(json.Boolean)
	return ok && bool(value)
}
