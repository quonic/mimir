package builtin_tools

import ai "../ai"
import tool_policy "../tool_policy"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Tool IDs for builtins (excludes search_code and find_code which are app-provided)
TOOL_READ_FILE :: "read_file"
TOOL_WRITE_FILE :: "write_file"
TOOL_REPLACE_STRING_IN_FILE :: "replace_string_in_file"
TOOL_IN_TERMINAL :: "run_in_terminal"
TOOL_LIST_SHELLS :: "list_available_shells"
TOOL_LIST_DIRECTORY :: "list_directory"
TOOL_GET_FILE_INFO :: "get_file_info"
TOOL_READ_SKILL :: "read_skill"
TOOL_RUN_SUBAGENT :: "run_subagent"
TOOL_PATCH_FILE :: "patch_file"
TOOL_GREP_SEARCH :: "grep_search" // TODO: Implement grep_search tool. Searches for a string in a file and returns the matching lines. Parameters: file_path, search_string, max_results

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

Patch_Line :: struct {
	text:       string,
	hasNewline: bool,
}

patch_line_text :: proc(line: string) -> string {
	if strings.ends_with(line, "\r") {
		return line[:len(line) - 1]
	}
	return line
}

patch_parse_range :: proc(text: string, index: ^int, prefix: u8) -> (int, int, bool) {
	if index^ >= len(text) || text[index^] != prefix {
		return 0, 0, false
	}
	index^ += 1
	startIndex := index^
	for index^ < len(text) && text[index^] >= '0' && text[index^] <= '9' {
		index^ += 1
	}
	if startIndex == index^ {
		return 0, 0, false
	}
	start, startOK := strconv.parse_int(text[startIndex:index^])
	if !startOK {
		return 0, 0, false
	}
	count := 1
	if index^ < len(text) && text[index^] == ',' {
		index^ += 1
		countIndex := index^
		for index^ < len(text) && text[index^] >= '0' && text[index^] <= '9' {
			index^ += 1
		}
		if countIndex == index^ {
			return 0, 0, false
		}
		count, startOK = strconv.parse_int(text[countIndex:index^])
		if !startOK {
			return 0, 0, false
		}
	}
	return start, count, true
}

patch_parse_hunk_header :: proc(
	line: string,
) -> (
	oldStart, oldCount, newStart, newCount: int,
	ok: bool,
) {
	if !strings.starts_with(line, "@@ ") {
		return
	}
	index := 3
	oldStart, oldCount, ok = patch_parse_range(line, &index, '-')
	if !ok || index >= len(line) || line[index] != ' ' {
		return 0, 0, 0, 0, false
	}
	index += 1
	newStart, newCount, ok = patch_parse_range(line, &index, '+')
	if !ok || index + 3 > len(line) || line[index:index + 3] != " @@" {
		return 0, 0, 0, 0, false
	}
	return oldStart, oldCount, newStart, newCount, true
}

patch_range_index :: proc(start, count: int) -> (int, bool) {
	if start < 0 || count < 0 || (start == 0 && count != 0) {
		return 0, false
	}
	if count == 0 {
		return start, true
	}
	return start - 1, true
}

patch_file :: proc(file_path: string, patch_content: string) -> string {
	data, readErr := os.read_entire_file_from_path(file_path, context.allocator)
	if readErr != nil {
		return fmt.aprintf("Error applying patch: could not read file: %s", readErr)
	}
	defer delete(data, context.allocator)

	source := string(data)
	usesCRLF := strings.contains(source, "\r\n")
	sourceParts := strings.split(source, "\n", context.allocator)
	defer delete(sourceParts, context.allocator)
	sourceCount := len(sourceParts)
	if strings.ends_with(source, "\n") {
		sourceCount -= 1
	}
	sourceLines := make([]Patch_Line, sourceCount, context.allocator)
	defer delete(sourceLines, context.allocator)
	for index in 0 ..< sourceCount {
		sourceLines[index] = Patch_Line {
			text       = patch_line_text(sourceParts[index]),
			hasNewline = index < sourceCount - 1 || strings.ends_with(source, "\n"),
		}
	}

	patchParts := strings.split(patch_content, "\n", context.allocator)
	defer delete(patchParts, context.allocator)
	patchCount := len(patchParts)
	if patchCount > 0 && patchParts[patchCount - 1] == "" {
		patchCount -= 1
	}
	headerIndex := -1
	for index in 0 ..< patchCount {
		line := patch_line_text(patchParts[index])
		if strings.starts_with(line, "Binary files ") ||
		   strings.starts_with(line, "rename from ") ||
		   strings.starts_with(line, "rename to ") {
			return strings.clone(
				"Error applying patch: binary and rename patches are not supported.",
				context.allocator,
			)
		}
		if strings.starts_with(line, "--- ") {
			headerIndex = index
			break
		}
	}
	if headerIndex < 0 || headerIndex + 1 >= patchCount {
		return strings.clone(
			"Error applying patch: missing unified diff file headers.",
			context.allocator,
		)
	}
	oldHeader := patch_line_text(patchParts[headerIndex])
	newHeader := patch_line_text(patchParts[headerIndex + 1])
	if !strings.starts_with(newHeader, "+++ ") {
		return strings.clone(
			"Error applying patch: expected new-file header after old-file header.",
			context.allocator,
		)
	}
	if strings.contains(oldHeader, "/dev/null") || strings.contains(newHeader, "/dev/null") {
		return strings.clone(
			"Error applying patch: creating and deleting files is not supported.",
			context.allocator,
		)
	}

	resultLines := make([dynamic]Patch_Line, 0, sourceCount, context.allocator)
	defer delete(resultLines)
	sourceIndex := 0
	patchIndex := headerIndex + 2
	hunkCount := 0
	for patchIndex < patchCount {
		header := patch_line_text(patchParts[patchIndex])
		if strings.starts_with(header, "--- ") || strings.starts_with(header, "diff --git ") {
			return strings.clone(
				"Error applying patch: multiple file patches are not supported.",
				context.allocator,
			)
		}
		oldStart, oldCount, newStart, newCount, headerOK := patch_parse_hunk_header(header)
		if !headerOK {
			return fmt.aprintf("Error applying patch: invalid hunk header: %s", header)
		}
		oldTarget, oldTargetOK := patch_range_index(oldStart, oldCount)
		newTarget, newTargetOK := patch_range_index(newStart, newCount)
		if !oldTargetOK || !newTargetOK || oldTarget < sourceIndex || oldTarget > sourceCount {
			return strings.clone(
				"Error applying patch: hunk range is outside the target file.",
				context.allocator,
			)
		}
		for sourceIndex < oldTarget {
			append(&resultLines, sourceLines[sourceIndex])
			sourceIndex += 1
		}
		if newTarget != len(resultLines) {
			return strings.clone(
				"Error applying patch: new-file hunk position is inconsistent.",
				context.allocator,
			)
		}

		patchIndex += 1
		seenOld, seenNew := 0, 0
		previousOperation: u8
		previousSourceIndex := -1
		for patchIndex < patchCount {
			line := patch_line_text(patchParts[patchIndex])
			if strings.starts_with(line, "@@ ") ||
			   strings.starts_with(line, "--- ") ||
			   strings.starts_with(line, "diff --git ") {
				break
			}
			if line == `\ No newline at end of file` {
				if previousOperation == '+' {
					resultLines[len(resultLines) - 1].hasNewline = false
				} else if previousOperation == ' ' || previousOperation == '-' {
					if previousSourceIndex < 0 || sourceLines[previousSourceIndex].hasNewline {
						return strings.clone(
							"Error applying patch: no-newline marker does not match target file.",
							context.allocator,
						)
					}
					if previousOperation == ' ' {
						resultLines[len(resultLines) - 1].hasNewline = false
					}
				} else {
					return strings.clone(
						"Error applying patch: misplaced no-newline marker.",
						context.allocator,
					)
				}
				previousOperation = 0
				patchIndex += 1
				continue
			}
			if len(line) == 0 || (line[0] != ' ' && line[0] != '+' && line[0] != '-') {
				return strings.clone("Error applying patch: invalid hunk line.", context.allocator)
			}
			operation := line[0]
			text := line[1:]
			switch operation {
			case ' ', '-':
				if sourceIndex >= sourceCount || sourceLines[sourceIndex].text != text {
					return fmt.aprintf(
						"Error applying patch: context mismatch at source line %d.",
						sourceIndex + 1,
					)
				}
				previousSourceIndex = sourceIndex
				if operation == ' ' {
					append(&resultLines, sourceLines[sourceIndex])
					seenNew += 1
				}
				sourceIndex += 1
				seenOld += 1
			case '+':
				append(&resultLines, Patch_Line{text = text, hasNewline = true})
				previousSourceIndex = -1
				seenNew += 1
			}
			previousOperation = operation
			patchIndex += 1
		}
		if seenOld != oldCount || seenNew != newCount {
			return fmt.aprintf(
				"Error applying patch: hunk count mismatch (expected -%d/+%d, got -%d/+%d).",
				oldCount,
				newCount,
				seenOld,
				seenNew,
			)
		}
		hunkCount += 1
	}
	if hunkCount == 0 {
		return strings.clone("Error applying patch: patch contains no hunks.", context.allocator)
	}
	for sourceIndex < sourceCount {
		append(&resultLines, sourceLines[sourceIndex])
		sourceIndex += 1
	}

	builder: strings.Builder
	strings.builder_init(&builder, context.allocator)
	newline := "\n"
	if usesCRLF {
		newline = "\r\n"
	}
	for line in resultLines {
		strings.write_string(&builder, line.text)
		if line.hasNewline {
			strings.write_string(&builder, newline)
		}
	}
	result := strings.to_string(builder)
	defer delete(result, context.allocator)
	writeErr := os.write_entire_file_from_string(file_path, result)
	if writeErr != nil {
		return fmt.aprintf("Error applying patch: could not write file: %s", writeErr)
	}
	return strings.clone("Patch applied successfully", context.allocator)
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
	definitions := make([dynamic]ai.Tool_Definition, 0, 12, allocator)
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
			name = TOOL_PATCH_FILE,
			description = "Apply a unified diff to an existing file in the active project",
			parametersJSON = `{"type":"object","properties":{"file_path":{"type":"string"},"patch_content":{"type":"string"}},"required":["file_path","patch_content"]}`,
		},
	)
	append(
		&definitions,
		ai.Tool_Definition {
			name = TOOL_IN_TERMINAL,
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
			name = TOOL_RUN_SUBAGENT,
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
	case TOOL_PATCH_FILE:
		path, pathOK := tool_policy.permission_resolve_project_path(
			dispatcher.projectRoot,
			call.filePath,
			dispatcher.allocator,
		)
		if !pathOK {
			return "Permission denied."
		}
		defer delete(path, dispatcher.allocator)
		return patch_file(path, call.patchContent)
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
	case TOOL_IN_TERMINAL:
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
