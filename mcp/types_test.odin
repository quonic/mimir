package mcp

import "core:encoding/json"
import "core:testing"

@(test)
test_parse_tools_reads_name_description_and_schema :: proc(t: ^testing.T) {
	raw := `{"resultType":"complete","tools":[{"name":"get_weather","description":"Get weather","inputSchema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}}],"nextCursor":"page2"}`
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.allocator)
	assert(err == .None, "expected fixture to parse")
	defer json.destroy_value(value, context.allocator)
	result := value.(json.Object)

	tools := parse_tools(result, context.allocator)
	defer tools_destroy(tools, context.allocator)
	assert(len(tools) == 1, "expected one tool")
	assert(tools[0].name == "get_weather", "expected tool name to round-trip")
	assert(tools[0].description == "Get weather", "expected tool description to round-trip")
	assert(
		tools[0].inputSchemaJSON != "",
		"expected inputSchema to be re-marshaled to a JSON string",
	)

	cursor := next_cursor(result, context.allocator)
	defer delete(cursor, context.allocator)
	assert(cursor == "page2", "expected nextCursor to round-trip")
}

@(test)
test_parse_resources_and_prompts_ignore_malformed_entries :: proc(t: ^testing.T) {
	raw := `{"resultType":"complete","resources":[{"uri":"file:///a.txt","name":"a.txt"},{"name":"missing uri"}]}`
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.allocator)
	assert(err == .None, "expected fixture to parse")
	defer json.destroy_value(value, context.allocator)
	result := value.(json.Object)

	resources := parse_resources(result, context.allocator)
	defer resources_destroy(resources, context.allocator)
	assert(len(resources) == 1, "expected the malformed entry (no uri) to be skipped")
	assert(resources[0].uri == "file:///a.txt", "expected resource uri to round-trip")
}

@(test)
test_render_content_text_joins_text_blocks_and_placeholders :: proc(t: ^testing.T) {
	raw := `{"resultType":"complete","content":[{"type":"text","text":"hello"},{"type":"image","data":"...","mimeType":"image/png"}],"isError":false}`
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.allocator)
	assert(err == .None, "expected fixture to parse")
	defer json.destroy_value(value, context.allocator)
	result := value.(json.Object)

	text := render_content_text(result, context.allocator)
	defer delete(text, context.allocator)
	assert(
		text == "hello\n[non-text content omitted: image]",
		"expected text block and image placeholder joined by newline",
	)
	assert(!result_is_error(result), "expected isError false to round-trip")
}

@(test)
test_result_is_error_true :: proc(t: ^testing.T) {
	raw := `{"resultType":"complete","content":[{"type":"text","text":"boom"}],"isError":true}`
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.allocator)
	assert(err == .None, "expected fixture to parse")
	defer json.destroy_value(value, context.allocator)
	result := value.(json.Object)
	assert(result_is_error(result), "expected isError true to round-trip")
}
