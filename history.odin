package main

import json "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

History_Error :: enum int {
	None = 0,
	Invalid_Path,
	Not_Found,
	Io_Error,
	Invalid_JSON,
}

history_cache_dir :: proc(home: string, allocator := context.allocator) -> string {
	if home == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, home)
	strings.write_string(&builder, "/.cache/mimir")
	return strings.to_string(builder)
}

input_history_path :: proc(
	home: string,
	workingDirectory: string,
	allocator := context.allocator,
) -> string {
	dir := history_cache_dir(home, allocator)
	defer delete(dir, allocator)
	if dir == "" || workingDirectory == "" {
		return ""
	}
	return fmt.aprintf(
		"%s/history-%016x.json",
		dir,
		hash.fnv64a(transmute([]byte)workingDirectory),
		allocator = allocator,
	)
}

load_input_history_from_file :: proc(
	home: string,
	workingDirectory: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	History_Error,
) {
	path := input_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if path == "" {
		return nil, .Invalid_Path
	}

	data, readErr := os.read_entire_file(path, context.temp_allocator)
	if readErr != nil {
		#partial switch err in readErr {
		case os.General_Error:
			if err == .Not_Exist {
				return nil, .Not_Found
			}
		}
		return nil, .Io_Error
	}

	wire: []string
	decodeErr := json.unmarshal_string(string(data), &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return nil, .Invalid_JSON
	}

	history := make([dynamic]string, 0, len(wire), allocator)
	for entry in wire {
		append(&history, strings.clone(entry, allocator))
	}
	return history, .None
}

save_input_history_to_file :: proc(
	home: string,
	workingDirectory: string,
	history: []string,
) -> History_Error {
	dir := history_cache_dir(home, context.temp_allocator)
	path := input_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(dir, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if dir == "" || path == "" {
		return .Invalid_Path
	}

	if !os.exists(dir) {
		mkdirErr := os.make_directory_all(dir)
		if mkdirErr != nil {
			return .Io_Error
		}
	}

	payload := input_history_to_json(history, context.temp_allocator)
	defer delete(payload, context.temp_allocator)
	if writeErr := os.write_entire_file_from_string(path, payload); writeErr != nil {
		return .Io_Error
	}
	return .None
}

clear_input_history_file :: proc(home: string, workingDirectory: string) -> History_Error {
	path := input_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if path == "" {
		return .Invalid_Path
	}
	if !os.exists(path) {
		return .None
	}
	if removeErr := os.remove(path); removeErr != nil {
		return .Io_Error
	}
	return .None
}

input_history_to_json :: proc(history: []string, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, "[")
	for entry, index in history {
		if index > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, "\n  ")
		write_json_string(&builder, entry)
	}
	if len(history) > 0 {
		strings.write_string(&builder, "\n")
	}
	strings.write_string(&builder, "]\n")
	return strings.to_string(builder)
}

write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index := 0; index < len(text); index += 1 {
		switch text[index] {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_byte(builder, text[index])
		}
	}
	strings.write_byte(builder, '"')
}
