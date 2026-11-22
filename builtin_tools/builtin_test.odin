package builtin_tools

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_builtin_ai_tool_definitions_returns_all_tools :: proc(t: ^testing.T) {
	definitions := builtin_ai_tool_definitions(context.temp_allocator)
	defer delete(definitions)

	assert(len(definitions) == 13, "expected 13 builtin tool definitions")

	// Verify all expected tools are present
	tool_names := make([]string, len(definitions), context.temp_allocator)
	for def, i in definitions {
		tool_names[i] = def.name
	}

	expected_tools := [13]string {
		"read_file",
		"read_skill",
		"write_file",
		"replace_string_in_file",
		"patch_file",
		"run_in_terminal",
		"list_available_shells",
		"list_directory",
		"get_file_info",
		"grep_search",
		"search_code",
		"find_code",
		"run_subagent",
	}

	for expected in expected_tools {
		found := false
		for name in tool_names {
			if name == expected {
				found = true
				break
			}
		}
		assert(found, "expected tool definition to be present")
	}
}

@(test)
test_grep_search_returns_matching_lines_as_json :: proc(t: ^testing.T) {
	tempDir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(tempDir)
	path := strings.concatenate({tempDir, "/search.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	writeErr := os.write_entire_file_from_string(
		path,
		"alpha 12\r\nbeta\r\nalpha 34\r\nalpha 56\r\n",
	)
	assert(writeErr == nil, "expected search fixture to be written")

	result := grep_search(path, `^alpha [0-9]+$`, 2)
	defer delete(result, context.allocator)
	assert(
		result ==
		`{"results":[{"line_number":1,"text":"alpha 12"},{"line_number":3,"text":"alpha 34"}]}`,
		"expected ordered, limited regex matches with normalized CRLF lines",
	)
	_ = t
}

@(test)
test_grep_search_escapes_json_and_reports_errors :: proc(t: ^testing.T) {
	tempDir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(tempDir)
	path := strings.concatenate({tempDir, "/search.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	writeErr := os.write_entire_file_from_string(path, "say \"hello\"\\world\nother\n")
	assert(writeErr == nil, "expected search fixture to be written")

	matched := grep_search(path, "hello", 50)
	defer delete(matched, context.allocator)
	assert(
		matched == `{"results":[{"line_number":1,"text":"say \"hello\"\\world"}]}`,
		"expected matching text to be JSON escaped",
	)

	noMatch := grep_search(path, "missing", 50)
	defer delete(noMatch, context.allocator)
	assert(noMatch == `{"results":[]}`, "expected an empty JSON result list")

	invalidPattern := grep_search(path, "[", 50)
	defer delete(invalidPattern, context.allocator)
	assert(
		strings.starts_with(invalidPattern, "Error compiling regular expression:"),
		"expected an invalid regex error",
	)
	_ = t
}

@(test)
test_read_file_tool_reads_existing_file :: proc(t: ^testing.T) {
	// Create a temp file
	temp_dir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(temp_dir)

	test_file_path := strings.concatenate({temp_dir, "/test.txt"}, context.temp_allocator)
	defer delete(test_file_path, context.temp_allocator)
	test_content := "Hello, World!"
	err := os.write_entire_file_from_string(test_file_path, test_content)
	assert(err == nil, "expected no error writing file")

	// Read the file using our tool
	result := read_file(test_file_path)
	defer delete(result, context.allocator)
	assert(result == test_content, "expected to read file content")
}

@(test)
test_read_file_tool_returns_error_for_nonexistent :: proc(t: ^testing.T) {
	result := read_file("/nonexistent/path/to/file.txt")
	defer delete(result, context.allocator)
	assert(
		strings.contains(result, "Error reading file"),
		"expected error message for nonexistent file",
	)
}

@(test)
test_write_file_tool_creates_new_file :: proc(t: ^testing.T) {
	temp_dir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(temp_dir)

	test_file_path := strings.concatenate({temp_dir, "/new.txt"}, context.temp_allocator)
	defer delete(test_file_path, context.temp_allocator)
	test_content := "New file content"

	result := write_file(test_file_path, test_content, "false")
	defer delete(result, context.allocator)
	assert(result == "File written successfully", "expected success message")
}

@(test)
test_patch_file_applies_multiple_hunks :: proc(t: ^testing.T) {
	tempDir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(tempDir)
	path := strings.concatenate({tempDir, "/test.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	writeErr := os.write_entire_file_from_string(path, "alpha\nbeta\ngamma\ndelta\n")
	assert(writeErr == nil, "expected fixture file to be written")

	patch := `--- a/test.txt
+++ b/test.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+BETA
@@ -4 +4,2 @@
 delta
+epsilon
`
	result := patch_file(path, patch)
	defer delete(result, context.allocator)
	assert(result == "Patch applied successfully", "expected patch to succeed")

	data, readErr := os.read_entire_file_from_path(path, context.temp_allocator)
	assert(readErr == nil, "expected patched file to be readable")
	assert(string(data) == "alpha\nBETA\ngamma\ndelta\nepsilon\n", "expected both hunks")
}

@(test)
test_patch_file_preserves_crlf_and_missing_final_newline :: proc(t: ^testing.T) {
	tempDir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(tempDir)
	path := strings.concatenate({tempDir, "/test.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	writeErr := os.write_entire_file_from_string(path, "one\r\ntwo")
	assert(writeErr == nil, "expected fixture file to be written")

	patch := `--- a/test.txt
+++ b/test.txt
@@ -1,2 +1,2 @@
 one
-two
\ No newline at end of file
+TWO
\ No newline at end of file
`
	result := patch_file(path, patch)
	defer delete(result, context.allocator)
	assert(result == "Patch applied successfully", "expected patch to succeed")

	data, readErr := os.read_entire_file_from_path(path, context.temp_allocator)
	assert(readErr == nil, "expected patched file to be readable")
	assert(string(data) == "one\r\nTWO", "expected CRLF and missing final newline preserved")
}

@(test)
test_patch_file_context_mismatch_leaves_file_unchanged :: proc(t: ^testing.T) {
	tempDir, _ := os.make_directory_temp("", "builtin_test_*", context.temp_allocator)
	defer os.remove_all(tempDir)
	path := strings.concatenate({tempDir, "/test.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	original := "alpha\nbeta\n"
	writeErr := os.write_entire_file_from_string(path, original)
	assert(writeErr == nil, "expected fixture file to be written")

	patch := `--- a/test.txt
+++ b/test.txt
@@ -1,2 +1,2 @@
 alpha
-missing
+replacement
`
	result := patch_file(path, patch)
	defer delete(result, context.allocator)
	assert(strings.starts_with(result, "Error applying patch:"), "expected patch to fail")

	data, readErr := os.read_entire_file_from_path(path, context.temp_allocator)
	assert(readErr == nil, "expected original file to remain readable")
	assert(string(data) == original, "expected failed patch not to modify the file")
}

@(test)
test_list_available_shells_returns_nonempty :: proc(t: ^testing.T) {
	result := list_available_shells()
	defer delete(result, context.allocator)
	assert(len(result) > 0, "expected at least one shell to be listed")
}

@(test)
test_write_file_reports_an_existing_file_in_its_result :: proc(t: ^testing.T) {
	directory, directoryErr := os.make_directory_temp("", "builtin-test-*", context.allocator)
	assert(directoryErr == nil, "expected a temporary directory")
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := strings.concatenate({directory, "/exists.txt"}, context.temp_allocator)
	assert(os.write_entire_file(path, "old") == nil, "expected the test file")

	// The message is only the tool result. Nothing is printed to stdout.
	result := write_file(path, "new", "false")
	defer delete(result)
	assert(
		result == "File already exists. Use overwrite option to replace it.",
		"expected the existing file to be reported in the result",
	)
	_ = t
}

// Parses a run_in_terminal result and returns its stdout and stderr fields.
parse_terminal_result :: proc(result: string) -> (stdout, stderr: string, ok: bool) {
	value, parseErr := json.parse_string(result, allocator = context.temp_allocator)
	if parseErr != nil {
		return "", "", false
	}
	object := value.(json.Object) or_return
	stdoutValue := object["stdout"].(json.String) or_return
	stderrValue := object["stderr"].(json.String) or_return
	return stdoutValue, stderrValue, true
}

@(test)
test_terminal_result_json_escapes_output :: proc(t: ^testing.T) {
	stdout := "say \"hi\"\npath C:\\tmp\ttab\r\x01bell\x7f héllo ✓"
	stderr := "warning: {braces} and %s"
	result := terminal_result_json(stdout, stderr)
	defer delete(result)

	assert(
		strings.has_prefix(result, `{"stdout": "`),
		fmt.tprintf("expected a JSON object, got %q", result),
	)
	parsedStdout, parsedStderr, ok := parse_terminal_result(result)
	assert(ok, fmt.tprintf("expected the result to parse as JSON, got %q", result))
	assert(
		parsedStdout == stdout,
		fmt.tprintf("expected stdout %q after a round trip, got %q", stdout, parsedStdout),
	)
	assert(
		parsedStderr == stderr,
		fmt.tprintf("expected stderr %q after a round trip, got %q", stderr, parsedStderr),
	)
	_ = t
}

@(test)
test_terminal_result_json_replaces_invalid_utf8 :: proc(t: ^testing.T) {
	result := terminal_result_json("ok \xff\xfe end", "")
	defer delete(result)

	parsedStdout, _, ok := parse_terminal_result(result)
	assert(ok, fmt.tprintf("expected the result to parse as JSON, got %q", result))
	assert(
		parsedStdout == "ok \uFFFD\uFFFD end",
		fmt.tprintf("expected invalid bytes to become U+FFFD, got %q", parsedStdout),
	)
	_ = t
}

@(test)
test_run_in_terminal_returns_valid_json :: proc(t: ^testing.T) {
	// The command runs in the platform shell, so it must produce output only that shell can: a
	// shell that ignored its arguments would not print the marker. Quotes, a backslash, braces
	// and non-ASCII text check the argument quoting and the output encoding.
	when ODIN_OS == .Windows {
		command := `Write-Output 'mimir-marker say "hi"'; Write-Output 'back\slash {x} héllo'`
	} else {
		command := `printf 'mimir-marker say "hi"\nback\\slash {x} héllo\n'`
	}
	result := run_in_terminal(command)
	defer delete(result)

	parsedStdout, parsedStderr, ok := parse_terminal_result(result)
	assert(ok, fmt.tprintf("expected the result to parse as JSON, got %q", result))
	stdout, _ := strings.replace_all(parsedStdout, "\r\n", "\n", context.temp_allocator)
	expected := "mimir-marker say \"hi\"\nback\\slash {x} héllo\n"
	assert(stdout == expected, fmt.tprintf("expected stdout %q, got %q", expected, stdout))
	assert(parsedStderr == "", fmt.tprintf("expected empty stderr, got %q", parsedStderr))
	_ = t
}

@(test)
test_run_in_terminal_tool_names_the_shell :: proc(t: ^testing.T) {
	definitions := builtin_ai_tool_definitions(context.temp_allocator)
	defer delete(definitions)
	description := ""
	for definition in definitions {
		if definition.name == TOOL_IN_TERMINAL {
			description = definition.description
		}
	}
	assert(
		strings.contains(description, TERMINAL_SHELL_NAME),
		fmt.tprintf(
			"expected the description to name %q, got %q",
			TERMINAL_SHELL_NAME,
			description,
		),
	)
	_ = t
}
