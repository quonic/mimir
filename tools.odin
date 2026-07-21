package main

Tool_Definition :: struct {
	id:          string,
	parameters:  [dynamic]Tool_Parameter,
	description: string,
	required:    [dynamic]string,
}

Tool_Parameter :: struct {
	name:        string,
	description: string,
	required:    bool,
}

Tool_Registry :: struct {
	definitions: [dynamic]Tool_Definition,
}

builtin_tool_registry :: proc(allocator := context.allocator) -> Tool_Registry {
	registry: Tool_Registry
	registry.definitions = make([dynamic]Tool_Definition, 0, 4, allocator)

	// read_file tool definition
	read_file_tool := Tool_Definition {
		id          = "read_file",
		description = "Read project files for context",
	}
	defer delete(read_file_tool.parameters)
	defer delete(read_file_tool.required)
	append(&read_file_tool.required, "file_path")
	append(
		&read_file_tool.parameters,
		Tool_Parameter {
			name = "file_path",
			description = "Path to the file to read",
			required = true,
		},
	)
	append(
		&read_file_tool.parameters,
		Tool_Parameter {
			name = "start_line",
			description = "The starting line number to read from",
			required = false,
		},
	)
	append(
		&read_file_tool.parameters,
		Tool_Parameter {
			name = "end_line",
			description = "The ending line number to read to",
			required = false,
		},
	)
	append(&registry.definitions, read_file_tool)

	// write_file tool definition
	write_file_tool := Tool_Definition {
		id          = "write_file",
		description = "Write files to the project for context",
	}
	defer delete(write_file_tool.parameters)
	defer delete(write_file_tool.required)
	append(&write_file_tool.required, "file_path")
	append(&write_file_tool.required, "content")
	append(
		&write_file_tool.parameters,
		Tool_Parameter {
			name = "file_path",
			description = "Path to the file to write",
			required = true,
		},
	)
	append(
		&write_file_tool.parameters,
		Tool_Parameter {
			name = "content",
			description = "The content to write to the file",
			required = true,
		},
	)
	append(
		&write_file_tool.parameters,
		Tool_Parameter {
			name = "overwrite",
			description = "Whether to overwrite the file if it exists",
			required = false,
		},
	)
	append(&registry.definitions, write_file_tool)

	// run_command tool definition
	run_command_tool := Tool_Definition {
		id          = "run_command",
		description = "Run a command in the project context",
	}
	defer delete(run_command_tool.parameters)
	defer delete(run_command_tool.required)
	append(&run_command_tool.required, "command")
	append(
		&run_command_tool.parameters,
		Tool_Parameter{name = "command", description = "The command to run", required = true},
	)
	append(
		&run_command_tool.parameters,
		Tool_Parameter {
			name = "working_directory",
			description = "The working directory to run the command in",
			required = false,
		},
	)
	append(
		&run_command_tool.parameters,
		Tool_Parameter {
			name = "timeout",
			description = "The timeout for the command in seconds",
			required = false,
		},
	)
	append(
		&run_command_tool.parameters,
		Tool_Parameter {
			name = "capture_output",
			description = "Whether to capture the command output",
			required = false,
		},
	)
	append(
		&run_command_tool.parameters,
		Tool_Parameter {
			name = "env_vars",
			description = "Environment variables to set for the command",
			required = false,
		},
	)
	append(
		&run_command_tool.parameters,
		Tool_Parameter {
			name = "shell",
			description = "The shell to use for the command",
			required = false,
		},
	)
	append(&registry.definitions, run_command_tool)

	// list_available_shells tool definition
	list_available_shells_tool := Tool_Definition {
		id          = "list_available_shells",
		description = "List available shells in the project context",
	}
	defer delete(list_available_shells_tool.parameters)
	append(&registry.definitions, list_available_shells_tool)

	// list_directory tool definition
	list_directory_tool := Tool_Definition {
		id          = "list_directory",
		description = "List the contents of a directory in the project context",
	}
	defer delete(list_directory_tool.parameters)
	defer delete(list_directory_tool.required)
	append(&list_directory_tool.required, "directory_path")
	append(
		&list_directory_tool.parameters,
		Tool_Parameter {
			name = "directory_path",
			description = "Path to the directory to list",
			required = true,
		},
	)
	append(&registry.definitions, list_directory_tool)

	// get_file_info tool definition
	get_file_info_tool := Tool_Definition {
		id          = "get_file_info",
		description = "Get information about a file in the project context",
	}
	defer delete(get_file_info_tool.parameters)
	defer delete(get_file_info_tool.required)
	append(&get_file_info_tool.required, "file_path")
	append(
		&get_file_info_tool.parameters,
		Tool_Parameter {
			name = "file_path",
			description = "Path to the file to get information about",
			required = true,
		},
	)
	append(&registry.definitions, get_file_info_tool)

	return registry
}
