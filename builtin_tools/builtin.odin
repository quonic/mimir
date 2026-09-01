package builtin_tools

import ai "../ai"
import tool_policy "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Tool IDs for builtins (excludes search_code and find_code which are app-provided)
TOOL_READ_FILE :: "read_file"
TOOL_WRITE_FILE :: "write_file"
TOOL_REPLACE_STRING_IN_FILE :: "replace_string_in_file"
TOOL_RUN_COMMAND :: "run_in_terminal"
TOOL_LIST_SHELLS :: "list_available_shells"
TOOL_LIST_DIRECTORY :: "list_directory"
TOOL_GET_FILE_INFO :: "get_file_info"
TOOL_READ_SKILL :: "read_skill"
TOOL_CREATE_SUBAGENT :: "create_subagent"

// ============================================================
// Filesystem Operations
// ============================================================

read_file :: proc(file_path: string) -> string {
	data, err := os.read_entire_file_from_path(file_path, context.allocator)
	if err != nil {
		return fmt.aprintf("Error reading file: %s", err)
	}
	defer delete(data, context.allocator)
	return strings.clone(string(data), context.allocator)
}

write_file :: proc(file_path: string, content: string, overwrite: string) -> string {
	if overwrite == "false" {
		if _, err := os.stat(file_path, context.allocator); err == nil {
			fmt.println("File already exists. Use overwrite option to replace it.")
			return strings.clone(
				"File already exists. Use overwrite option to replace it.",
				context.allocator,
			)
		}
	} else if overwrite == "true" {
		if _, err := os.stat(file_path, context.allocator); err == nil {
			rm_err := os.remove(file_path)
			if rm_err != nil {
				return fmt.aprintf("Error overwriting file: %s", rm_err)
			}
		}
	} else {
		return fmt.aprintf("Invalid value for overwrite: %s. Use 'true' or 'false'.", overwrite)
	}
	err := os.write_entire_file_from_string(file_path, content)
	if err != nil {
		return fmt.aprintf("Error writing file: %s", err)
	}
	return strings.clone("File written successfully", context.allocator)
}

replace_string_in_file :: proc(file_path: string, old: string, new: string) -> string {
	content := read_file(file_path)
	if strings.contains(content, old) {
		content, _ = strings.replace(content, old, new, -1, context.allocator)
		write_file(file_path, content, "true")
		return strings.clone("String replaced successfully", context.allocator)
	} else {
		return strings.clone("String not found in file", context.allocator)
	}
}

list_directory :: proc(directory_path: string) -> string {
	file_infos, err := os.read_directory_by_path(directory_path, 0, context.allocator)
	if err != nil {
		return fmt.aprintf("list_directory_tool: Error reading directory: %s", err)
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	json_data, marshal_err := json.marshal(file_infos, allocator = context.allocator)
	if marshal_err != nil {
		return fmt.aprintf(
			"list_directory_tool: Error converting results to JSON: %s",
			marshal_err,
		)
	}
	defer delete(json_data, context.allocator)
	return strings.clone(string(json_data), context.allocator)
}

get_file_info :: proc(file_path: string) -> string {
	file_info, err := os.stat(file_path, context.allocator)
	if err != nil {
		return fmt.aprintf("get_file_info_tool: Error reading file info: %s", err)
	}
	json_data, marshal_err := json.marshal(file_info, allocator = context.allocator)
	if marshal_err != nil {
		return fmt.aprintf("get_file_info_tool: Error converting results to JSON: %s", marshal_err)
	}
	defer delete(json_data, context.allocator)
	return strings.clone(string(json_data), context.allocator)
}

// ============================================================
// Shell Operations
// ============================================================

get_default_shell :: proc() -> string {
	if ODIN_OS == .Windows {
		return `C:\Windows\System32\cmd.exe`
	} else if ODIN_OS == .Linux ||
	   ODIN_OS == .Darwin ||
	   ODIN_OS == .FreeBSD ||
	   ODIN_OS == .OpenBSD ||
	   ODIN_OS == .NetBSD {
		return `/bin/bash`
	} else {
		return ""
	}
}

list_available_shells :: proc() -> string {
	shells := [dynamic]string{}
	defer delete(shells)
	if ODIN_OS == .Windows {
		if os.exists(`C:\Windows\System32\cmd.exe`) {
			append(&shells, `C:\Windows\System32\cmd.exe`)
		}
		if os.exists(`C:\Windows\System32\powershell.exe`) {
			append(&shells, `C:\Windows\System32\powershell.exe`)
		}
		if os.exists(`C:\Program Files\PowerShell\7\pwsh.exe`) {
			append(&shells, `C:\Program Files\PowerShell\7\pwsh.exe`)
		}
		if len(shells) == 0 {
			return strings.clone(
				"list_available_shells_tool: No shells found on Windows. This should not happen. Please report this issue to the user.",
				context.allocator,
			)
		}

	} else if ODIN_OS == .Linux ||
	   ODIN_OS == .Darwin ||
	   ODIN_OS == .FreeBSD ||
	   ODIN_OS == .OpenBSD ||
	   ODIN_OS == .NetBSD {
		data, err := os.read_entire_file_from_path("/etc/shells", context.allocator)
		if err == nil {
			defer delete(data, context.allocator)
			lines := strings.split(string(data), "\n")
			defer delete(lines)
			for &line in lines {
				line = strings.trim(line, " \t")
				if line != "" && !strings.starts_with(line, "#") {
					append(&shells, line)
				}
			}
		} else {
			fmt.println("list_available_shells_tool: Error reading /etc/shells:", err)
		}
	} else {
		return fmt.aprintf("list_available_shells_tool: Unsupported OS: %s", ODIN_OS)
	}
	joined_shells := strings.join(shells[:], ", ")
	return joined_shells
}

run_in_terminal :: proc(
	command: string,
	working_directory: string = "",
	timeout: int = 0,
) -> string {
	shell := get_default_shell()
	if shell == "" {
		return fmt.aprintf("run_in_terminal_tool: Unsupported OS: %s", ODIN_OS)
	}

	proc_desc := os.Process_Desc {
		command = {shell, "-c", command},
	}
	workingDirectoryOwned := false
	if working_directory == "" {
		{
			gwd_err: os.Error
			proc_desc.working_dir, gwd_err = os.get_working_directory(context.allocator)
			if gwd_err != nil {
				return fmt.aprintf(
					"run_in_terminal_tool: Error getting working directory: %s",
					gwd_err,
				)
			}
			workingDirectoryOwned = true
		}
	} else if !os.is_directory(working_directory) {
		return fmt.aprintf(
			"run_in_terminal_tool: Working directory does not exist: %s",
			working_directory,
		)
	} else {
		proc_desc.working_dir = working_directory
	}
	defer if workingDirectoryOwned {
		delete(proc_desc.working_dir, context.allocator)
	}
	proc_desc.env, _ = os.environ(context.allocator)
	defer {
		for environmentEntry in proc_desc.env {
			delete(environmentEntry, context.allocator)
		}
		delete(proc_desc.env, context.allocator)
	}

	state, stdout, stderr, err := os.process_exec(proc_desc, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil {
		return fmt.aprintf("run_in_terminal_tool: Error executing command `%s`: %s", command, err)
	}
	if state.exit_code != 0 {
		return fmt.aprintf(
			"run_in_terminal_tool: Command exited with code %d. Stderr: %s",
			state.exit_code,
			string(stderr),
		)
	}
	return fmt.aprintf(`{"stdout": "%s", "stderr": "%s"}`, string(stdout), string(stderr))
}

// ============================================================
// Tool Definitions and Execution Boundary
// ============================================================

// AI-compatible tool definitions for providers
builtin_ai_tool_definitions :: proc(
	allocator := context.allocator,
) -> [dynamic]ai.Tool_Definition {
	definitions := make([dynamic]ai.Tool_Definition, 0, 10, allocator)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_READ_FILE,
			description = "Read a file in the active project",
			parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_READ_SKILL,
			description = "Load the instructions for an enabled skill by name",
			parametersJSON = `{"type":"object","properties":{"name":{"type":"string"},"resource":{"type":"string"}},"required":["name"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_WRITE_FILE,
			description = "Write a file in the active project",
			parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"string","enum":["true","false"]}},"required":["file_path","content"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_REPLACE_STRING_IN_FILE,
			description = "Replace a string in a file in the active project",
			parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["file_path","old","new"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_RUN_COMMAND,
			description = "Run a shell command in the active project",
			parametersJSON = `{"type":"object","properties":{"command":{"type":"string"},"working_directory":{"type":"string"},"timeout":{"type":"integer"}},"required":["command"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_LIST_SHELLS,
			description = "List available shells",
			parametersJSON = `{"type":"object","properties":{}}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_LIST_DIRECTORY,
			description = "List a directory in the active project",
			parametersJSON = `{"type":"object","properties":{"directory_path":{"type":"string"}},"required":["directory_path"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_GET_FILE_INFO,
			description = "Get metadata for a file in the active project",
			parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"}},"required":["file_path"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_CREATE_SUBAGENT,
			description = "Delegate a self-contained task to a child agent and wait for its final answer",
			parametersJSON = `{"type":"object","properties":{"task":{"type":"string","description":"The self-contained task for the subagent to complete"},"tools":{"type":"array","items":{"type":"string"},"description":"Names of tools the subagent is allowed to use"},"depth":{"type":"integer","description":"How many further levels of subagents this subagent may itself spawn"}},"required":["task","tools"]}`,
		},
	)
	// Note: search_code and find_code are included here for API compatibility with AI providers,
	// but they remain application-provided (require live code index + embedding client).
	append(
		&definitions,
		ai.Tool_Definition {
			name = "search_code",
			description = "Semantically search the active project for code relevant to a query",
			parametersJSON = `{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer"}},"required":["query"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = "find_code",
			description = "Find exact text in active-project code, including identifiers and signatures",
			parametersJSON = `{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer"}},"required":["query"]}`,
		},
	)
	return definitions
}

// Execute a builtin tool call. Returns result string or error message.
// Uses tool_policy for path resolution to ensure security boundaries.
execute_builtin_tool :: proc(
	dispatcher: ^tool_policy.Tool_Dispatcher,
	call: tool_policy.Tool_Call,
) -> string {
	prepared := tool_policy.tool_dispatch_prepare(dispatcher, call)
	defer tool_policy.tool_dispatch_result_destroy(&prepared, dispatcher.allocator)

	switch prepared.decision {
	case .Denied:
		return "Permission denied."
	case .Approval_Required, .Allowed_Read_Only, .Allowed_Session, .Allowed_Persistent:
	// The caller has either received policy approval or explicitly authorized this call once.
	case:
		return "Permission denied."
	}

	switch call.id {
	case TOOL_LIST_SHELLS:
		return list_available_shells()
	case TOOL_READ_FILE:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return read_file(path)
	case TOOL_WRITE_FILE:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return write_file(path, call.content, call.overwrite)
	case TOOL_LIST_DIRECTORY:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.directoryPath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return list_directory(path)
	case TOOL_GET_FILE_INFO:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return get_file_info(path)
	case TOOL_RUN_COMMAND:
		workingDirectory := dispatcher.projectRoot
		if call.workingDirectory != "" {
			resolvedDirectory, directoryOK := tool_policy.permission_resolve_project_path(
				dispatcher.projectRoot,
				call.workingDirectory,
				dispatcher.allocator,
			)
			if !directoryOK {
				return "Permission denied."
			}
			defer delete(resolvedDirectory, dispatcher.allocator)
			workingDirectory = resolvedDirectory
		}
		return run_in_terminal(call.command, workingDirectory, call.timeout)
	case TOOL_REPLACE_STRING_IN_FILE:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return replace_string_in_file(path, call.old, call.new)
	case:
		return fmt.aprintf("Unknown builtin tool: %s", call.id)
	}

	return "Permission denied."
}
