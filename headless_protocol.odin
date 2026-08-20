package main

import json "core:encoding/json"
import "core:strings"

Headless_Request :: struct {
	id:     string,
	hasID:  bool,
	action: string,
	object: json.Object,
	raw:    json.Value,
}

headless_request_destroy :: proc(request: ^Headless_Request, allocator := context.allocator) {
	if request.raw != nil {
		json.destroy_value(request.raw, allocator)
	}
	request^ = {}
}

headless_parse_request :: proc(
	line: string,
	allocator := context.allocator,
) -> (
	Headless_Request,
	string,
	bool,
) {
	value, parseErr := json.parse_string(line, parse_integers = true, allocator = allocator)
	if parseErr != .None {
		return Headless_Request{}, "invalid JSON", false
	}

	object, objectOK := value.(json.Object)
	if !objectOK {
		json.destroy_value(value, allocator)
		return Headless_Request{}, "request must be a JSON object", false
	}

	actionValue, hasAction := object["action"]
	if !hasAction {
		json.destroy_value(value, allocator)
		return Headless_Request{}, "missing action", false
	}
	action, actionOK := actionValue.(json.String)
	if !actionOK || string(action) == "" {
		json.destroy_value(value, allocator)
		return Headless_Request{}, "action must be a non-empty string", false
	}

	request := Headless_Request {
		action = string(action),
		object = object,
		raw    = value,
	}
	if idValue, hasID := object["id"]; hasID {
		id, idOK := idValue.(json.String)
		if !idOK {
			json.destroy_value(value, allocator)
			return Headless_Request{}, "id must be a string", false
		}
		request.id = string(id)
		request.hasID = true
	}

	return request, "", true
}

headless_object_set :: proc(
	object: ^json.Object,
	key: string,
	value: json.Value,
	allocator := context.allocator,
) {
	object[strings.clone(key, allocator)] = value
}

headless_string_value :: proc(value: string, allocator := context.allocator) -> json.Value {
	return json.String(strings.clone(value, allocator))
}

headless_base_event :: proc(
	kind: string,
	request: ^Headless_Request,
	allocator := context.allocator,
) -> json.Object {
	object := json.Object(make(map[string]json.Value, 4, allocator))
	headless_object_set(&object, "type", headless_string_value(kind, allocator), allocator)
	if request != nil && request.hasID {
		headless_object_set(&object, "id", headless_string_value(request.id, allocator), allocator)
	}
	return object
}

headless_encode_event :: proc(
	object: json.Object,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	encoded, marshalErr := json.marshal(json.Value(object), allocator = allocator)
	if marshalErr != nil {
		return "", false
	}
	defer delete(encoded, allocator)
	return strings.clone(string(encoded), allocator), true
}
