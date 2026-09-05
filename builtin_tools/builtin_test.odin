package builtin_tools

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_builtin_ai_tool_definitions_returns_all_tools :: proc(t: ^testing.T) {
	definitions := builtin_ai_tool_definitions(context.temp_allocator)
	defer delete(definitions)

	assert(len(definitions) == 12, "expected 12 builtin tool definitions")

	// Verify all expected tools are present
	tool_names := make([]string, len(definitions), context.temp_allocator)
	for def, i in definitions {
		tool_names[i] = def.name
	}

	expected_tools := [12]string {
		"read_file",
		"read_skill",
		"write_file",
		"replace_string_in_file",
		"patch_file",
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
