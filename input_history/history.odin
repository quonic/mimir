package input_history

import json "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

Error :: enum int {
	None = 0,
	Invalid_Path,
	Not_Found,
	Io_Error,
	Invalid_JSON,
}

cache_directory :: proc(home: string, allocator := context.allocator) -> string {
	if home == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, home)
	strings.write_string(&builder, "/.cache/mimir")
	return strings.to_string(builder)
}

project_history_path :: proc(
	home: string,
	workingDirectory: string,
	allocator := context.allocator,
) -> string {
	directory := cache_directory(home, allocator)
	defer delete(directory, allocator)
	if directory == "" || workingDirectory == "" {
		return ""
	}
	return fmt.aprintf(
		"%s/history-%016x.json",
		directory,
		hash.fnv64a(transmute([]byte)workingDirectory),
		allocator = allocator,
	)
}

// The caller owns the returned dynamic array and every string it contains.
load :: proc(
	home: string,
	workingDirectory: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	Error,
) {
	path := project_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if path == "" {
		return nil, .Invalid_Path
	}

	data, readError := os.read_entire_file(path, context.temp_allocator)
	if readError != nil {
		#partial switch err in readError {
		case os.General_Error:
			if err == .Not_Exist {
				return nil, .Not_Found
			}
		}
		return nil, .Io_Error
	}

	wire: []string
	decodeError := json.unmarshal_string(string(data), &wire, allocator = context.temp_allocator)
	if decodeError != nil {
		return nil, .Invalid_JSON
	}

	history := make([dynamic]string, 0, len(wire), allocator)
	for entry in wire {
		append(&history, strings.clone(entry, allocator))
	}
	return history, .None
}

save :: proc(home: string, workingDirectory: string, history: []string) -> Error {
	directory := cache_directory(home, context.temp_allocator)
	path := project_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(directory, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if directory == "" || path == "" {
		return .Invalid_Path
	}

	if !os.exists(directory) {
		makeDirectoryError := os.make_directory_all(directory)
		if makeDirectoryError != nil {
			return .Io_Error
		}
	}

	payload := history_to_json(history, context.temp_allocator)
	defer delete(payload, context.temp_allocator)
	if writeError := os.write_entire_file_from_string(path, payload); writeError != nil {
		return .Io_Error
	}
	return .None
}

clear :: proc(home: string, workingDirectory: string) -> Error {
	path := project_history_path(home, workingDirectory, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if path == "" {
		return .Invalid_Path
	}
	if !os.exists(path) {
		return .None
	}
	if removeError := os.remove(path); removeError != nil {
		return .Io_Error
	}
	return .None
}

history_to_json :: proc(history: []string, allocator := context.allocator) -> string {
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