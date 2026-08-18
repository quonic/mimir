package mcp

import "core:encoding/json"
import "core:strings"

// Extracts the final JSON-RPC response object from a Streamable HTTP SSE
// response body. Notification events (no `result`/`error` field, e.g.
// `notifications/progress`) are skipped; comment lines (starting with `:`)
// are ignored per the SSE spec. Returns the raw JSON text of the final
// response event, or ok=false if none was found.
sse_extract_final_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	lines := strings.split(body, "\n")
	defer delete(lines)

	event: strings.Builder
	strings.builder_init(&event, context.temp_allocator)
	defer strings.builder_destroy(&event)

	finalJSON := ""
	found := false

	flush_event :: proc(
		event: ^strings.Builder,
		finalJSON: ^string,
		found: ^bool,
		allocator := context.allocator,
	) {
		payload := strings.to_string(event^)
		if payload == "" {
			return
		}
		value, err := json.parse_string(payload, allocator = context.temp_allocator)
		if err != .None {
			return
		}
		if object, isObject := value.(json.Object); isObject {
			_, hasResult := object["result"]
			_, hasError := object["error"]
			if hasResult || hasError {
				if found^ {
					delete(finalJSON^, allocator)
				}
				finalJSON^ = strings.clone(payload, allocator)
				found^ = true
			}
		}
	}

	for line in lines {
		trimmed := strings.trim_right(line, "\r")
		if trimmed == "" {
			flush_event(&event, &finalJSON, &found, allocator)
			strings.builder_reset(&event)
			continue
		}
		if strings.starts_with(trimmed, ":") {
			continue
		}
		if !strings.starts_with(trimmed, "data:") {
			continue
		}
		data := strings.trim_prefix(trimmed, "data:")
		data = strings.trim_left(data, " ")
		if strings.builder_len(event) > 0 {
			strings.write_byte(&event, '\n')
		}
		strings.write_string(&event, data)
	}
	flush_event(&event, &finalJSON, &found, allocator)

	return finalJSON, found
}
