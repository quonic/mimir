package acp

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

// JSON helpers for ACP messages. Outbound messages are built as json.Value trees in the
// temporary allocator and marshaled with core:encoding/json, which escapes newlines, so each
// message fits on one line. Inbound messages are parsed into the temporary allocator too; a
// value that the connection keeps is cloned.

Json_Field :: struct {
	key:   string,
	value: json.Value,
}

// Returns an object with fields, in the temporary allocator. A nil value is written as null.
json_object :: proc(fields: ..Json_Field) -> json.Value {
	object := make(json.Object, len(fields), context.temp_allocator)
	for field in fields {
		object[field.key] = field.value
	}
	return object
}

// Returns an array with values, in the temporary allocator.
json_array :: proc(values: ..json.Value) -> json.Value {
	array := make(json.Array, 0, len(values), context.temp_allocator)
	append(&array, ..values)
	return array
}

// Returns text as a JSON string. Text that is not valid UTF-8 gets U+FFFD for each bad byte,
// because ACP messages must be UTF-8.
json_text :: proc(text: string) -> json.Value {
	if utf8.valid_string(text) {
		return json.String(text)
	}
	builder := strings.builder_make(0, len(text), context.temp_allocator)
	for index := 0; index < len(text); {
		r, size := utf8.decode_rune_in_string(text[index:])
		if r == utf8.RUNE_ERROR && size <= 1 {
			strings.write_rune(&builder, utf8.RUNE_ERROR)
			index += 1
			continue
		}
		strings.write_string(&builder, text[index:index + size])
		index += size
	}
	return json.String(strings.to_string(builder))
}

json_integer :: proc(value: int) -> json.Value {
	return json.Integer(i64(value))
}

// Marshals value to one line. The result is in allocator.
json_marshal_line :: proc(value: json.Value, allocator := context.allocator) -> (string, bool) {
	data, err := json.marshal(value, {sort_maps_by_key = true}, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return strings.clone(string(data), allocator), true
}

json_get :: proc(object: json.Object, key: string) -> (json.Value, bool) {
	value, ok := object[key]
	return value, ok
}

// Returns the object field key. A missing field or another type returns false.
json_get_object :: proc(object: json.Object, key: string) -> (json.Object, bool) {
	value, ok := object[key]
	if !ok {
		return nil, false
	}
	result, isObject := value.(json.Object)
	return result, isObject
}

json_get_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, ok := object[key]
	if !ok {
		return "", false
	}
	result, isString := value.(json.String)
	return string(result), isString
}

json_get_array :: proc(object: json.Object, key: string) -> (json.Array, bool) {
	value, ok := object[key]
	if !ok {
		return nil, false
	}
	result, isArray := value.(json.Array)
	return result, isArray
}

json_get_integer :: proc(object: json.Object, key: string) -> (i64, bool) {
	value, ok := object[key]
	if !ok {
		return 0, false
	}
	result, isInteger := value.(json.Integer)
	return i64(result), isInteger
}

// Reports whether the field key is present and is not null or false.
json_has_value :: proc(object: json.Object, key: string) -> bool {
	value, ok := object[key]
	if !ok || value == nil {
		return false
	}
	#partial switch v in value {
	case json.Null:
		return false
	case json.Boolean:
		return bool(v)
	}
	return true
}

// Reports whether value is a valid JSON-RPC request ID: a string, a number or null.
json_is_request_id :: proc(value: json.Value) -> bool {
	#partial switch _ in value {
	case json.String, json.Integer, json.Float, json.Null:
		return true
	}
	return value == nil
}

// Copies a request ID into allocator. null becomes nil, which marshals as null.
json_request_id_clone :: proc(value: json.Value, allocator := context.allocator) -> json.Value {
	#partial switch v in value {
	case json.String:
		return json.String(strings.clone(string(v), allocator))
	case json.Integer:
		return v
	case json.Float:
		return v
	}
	return nil
}

json_request_id_destroy :: proc(value: ^json.Value, allocator := context.allocator) {
	if text, isString := value.(json.String); isString {
		delete(string(text), allocator)
	}
	value^ = nil
}

// Reports whether two request IDs are equal.
json_request_id_equal :: proc(a, b: json.Value) -> bool {
	#partial switch x in a {
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Integer:
		if y, ok := b.(json.Integer); ok {
			return x == y
		}
		if y, ok := b.(json.Float); ok {
			return f64(x) == f64(y)
		}
		return false
	case json.Float:
		if y, ok := b.(json.Float); ok {
			return x == y
		}
		if y, ok := b.(json.Integer); ok {
			return f64(x) == f64(y)
		}
		return false
	}
	return false
}
