package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// All tools take in strings and output strings.

read_file_tool_proc := proc(file_path: string, start_line: string, end_line: string) -> string {
	start_line_int: int = 0
	end_line_int: int = 0
	ok: bool = false

	data, err := os.read_entire_file_from_path(file_path, context.allocator)
	if err != nil {
		return fmt.aprintf("Error reading file: %s", err)
	}
	defer delete(data, context.allocator)
	start_line_int, ok = strconv.parse_int(start_line)
	if !ok {
		return fmt.aprintf("Error parsing start_line: %s", start_line)
	}
	end_line_int, ok = strconv.parse_int(end_line)
	if !ok {
		return fmt.aprintf("Error parsing end_line: %s", end_line)
	}
	if start_line_int == 0 && end_line_int == 0 {
		return strings.clone(string(data), context.allocator)
	}
	// If start_line or end_line are specified, extract the relevant lines
	lines := strings.split(string(data), "\n")
	defer delete(lines, context.allocator)
	if end_line_int == 0 || end_line_int > len(lines) {
		end_line_int = len(lines)
	}
	joined_lines := strings.join(lines[start_line_int:end_line_int], "\n")
	return joined_lines

}

write_file_tool_proc := proc(file_path: string, content: string, overwrite: string) -> string {
	if overwrite == "false" {
		if _, err := os.stat(file_path, context.allocator); err == nil {
			fmt.println("File already exists. Use overwrite option to replace it.")
			return "File already exists. Use overwrite option to replace it."
		}
	} else if overwrite == "true" {
		// If overwrite is true, delete the existing file
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
	return "File written successfully"
}

run_command_tool_proc := proc(
	command: string,
	working_directory: string = "",
	timeout: int = 0,
) -> string {
	shell := get_default_shell()
	if shell == "" {
		return fmt.aprintf("run_command_tool: Unsupported OS: %s", ODIN_OS)
	}

	proc_desc := os.Process_Desc {
		command = {shell, "-c", command},
	}
	if working_directory != "" {
		proc_desc.working_dir = working_directory
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
		return fmt.aprintf("run_command_tool: Error executing command: %s", err)
	}
	if state.exit_code != 0 {
		return fmt.aprintf(
			"run_command_tool: Command exited with code %d. Stderr: %s",
			state.exit_code,
			string(stderr),
		)
	}
	return fmt.aprintf("{\"stdout\": \"%s\", \"stderr\": \"%s\"}", string(stdout), string(stderr))
}

get_default_shell :: proc() -> string {
	if ODIN_OS == .Windows {
		return "C:\\Windows\\System32\\cmd.exe"
	} else if ODIN_OS == .Linux ||
	   ODIN_OS == .Darwin ||
	   ODIN_OS == .FreeBSD ||
	   ODIN_OS == .OpenBSD ||
	   ODIN_OS == .NetBSD {
		return "/bin/bash"
	} else {
		return ""
	}
}

list_available_shells_tool_proc := proc() -> string {
	shells := [dynamic]string{}
	if ODIN_OS == .Windows {
		// cmd.exe
		if os.exists("C:\\Windows\\System32\\cmd.exe") {
			append(&shells, "C:\\Windows\\System32\\cmd.exe")
		}
		// PowerShell 5.1
		if os.exists("C:\\Windows\\System32\\powershell.exe") {
			append(&shells, "C:\\Windows\\System32\\powershell.exe")
		}
		// PowerShell 7
		if os.exists("C:\\Program Files\\PowerShell\\7\\pwsh.exe") {
			append(&shells, "C:\\Program Files\\PowerShell\\7\\pwsh.exe")
		}
		if len(shells) == 0 {
			return(
				"list_available_shells_tool: No shells found on Windows. This should not happen. Please report this issue to the user." \
			)
		}

	} else if ODIN_OS == .Linux ||
	   ODIN_OS == .Darwin ||
	   ODIN_OS == .FreeBSD ||
	   ODIN_OS == .OpenBSD ||
	   ODIN_OS == .NetBSD {
		data, err := os.read_entire_file_from_path("/etc/shells", context.allocator)
		if err == nil {
			lines := strings.split(string(data), "\n")
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
	defer delete(joined_shells, context.allocator)
	return joined_shells
}

list_directory_tool_proc := proc(directory_path: string) -> string {
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

get_file_info_tool_proc := proc(file_path: string) -> string {
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
