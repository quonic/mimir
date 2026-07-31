package main

import builtin_tools "./builtin_tools"
import "ai"

// Local registry type for backward compatibility with app.odin
Tool_Registry :: struct {
	definitions: [dynamic]ai.Tool_Definition,
}

// Re-export builtin_ai_tool_definitions from builtin_tools package
builtin_ai_tool_definitions :: proc(
	allocator := context.allocator,
) -> [dynamic]ai.Tool_Definition {
	return builtin_tools.builtin_ai_tool_definitions(allocator)
}

// Legacy registry function - populates from builtin definitions for backward compatibility
builtin_tool_registry :: proc(allocator := context.allocator) -> Tool_Registry {
	registry: Tool_Registry
	definitions := builtin_ai_tool_definitions(allocator)
	// Copy definitions into the registry (we own this copy now)
	for def in definitions {
		append(
			&registry.definitions,
			ai.Tool_Definition {
				name = def.name,
				description = def.description,
				parametersJSON = def.parametersJSON,
			},
		)
	}
	delete(definitions) // Free the temporary array but not its contents (they're copied)
	return registry
}

// Backward compatibility shims for tool_proc functions used in tests
// These delegate to builtin_tools implementations
read_file_tool_proc :: proc(file_path: string) -> string {
	return builtin_tools.read_file(file_path)
}

write_file_tool_proc :: proc(file_path: string, content: string, overwrite: string) -> string {
	return builtin_tools.write_file(file_path, content, overwrite)
}

run_command_tool_proc :: proc(
	command: string,
	working_directory: string = "",
	timeout: int = 0,
) -> string {
	return builtin_tools.run_command(command, working_directory, timeout)
}

list_available_shells_tool_proc :: proc() -> string {
	return builtin_tools.list_available_shells()
}

list_directory_tool_proc :: proc(directory_path: string) -> string {
	return builtin_tools.list_directory(directory_path)
}

get_file_info_tool_proc :: proc(file_path: string) -> string {
	return builtin_tools.get_file_info(file_path)
}
