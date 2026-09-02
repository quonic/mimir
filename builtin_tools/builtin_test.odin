package builtin_tools

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_builtin_ai_tool_definitions_returns_8_tools :: proc(t: ^testing.T) {
	definitions := builtin_ai_tool_definitions(context.temp_allocator)
	defer delete(definitions)

	assert(len(definitions) == 11, "expected 11 builtin tool definitions")

	// Verify all expected tools are present
	tool_names := make([]string, len(definitions), context.temp_allocator)
	for def, i in definitions {
		tool_names[i] = def.name
	}

	expected_tools := [10]string {
		"read_file",
		"write_file",
		"replace_string_in_file",
		"run_in_terminal",
		"list_available_shells",
		"list_directory",
		"get_file_info",
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
test_list_available_shells_returns_nonempty :: proc(t: ^testing.T) {
	result := list_available_shells()
	defer delete(result, context.allocator)
	assert(len(result) > 0, "expected at least one shell to be listed")
}
