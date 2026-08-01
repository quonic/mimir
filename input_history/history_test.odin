package input_history

import "core:os"
import "core:strings"
import "core:testing"

destroy_history :: proc(history: ^[dynamic]string, allocator := context.allocator) {
	for &entry in history {
		delete(entry, allocator)
		entry = ""
	}
	delete(history^, allocator)
}

@(test)
test_save_load_and_clear_project_history :: proc(t: ^testing.T) {
	home, temporaryDirectoryError := os.make_directory_temp(
		"",
		"mimir-history-*",
		context.temp_allocator,
	)
	assert(temporaryDirectoryError == nil, "expected temporary home directory")
	defer os.remove_all(home)

	projectA := "/tmp/project-a"
	projectB := "/tmp/project-b"
	historyA := [2]string{"quoted \"entry\"\\tab\treturn\r\nnext line", "second entry"}
	historyB := [1]string{"other project"}

	assert(save(home, projectA, historyA[:]) == .None, "expected first history to save")
	assert(save(home, projectB, historyB[:]) == .None, "expected second history to save")

	loadedA, loadErrorA := load(home, projectA, context.temp_allocator)
	defer destroy_history(&loadedA, context.temp_allocator)
	assert(loadErrorA == .None, "expected first history to load")
	assert(len(loadedA) == 2, "expected all first history entries")
	assert(loadedA[0] == historyA[0], "expected escaped entry to round trip")

	assert(clear(home, projectA) == .None, "expected first history to clear")
	_, missingError := load(home, projectA, context.temp_allocator)
	assert(missingError == .Not_Found, "expected cleared history file to be absent")

	loadedB, loadErrorB := load(home, projectB, context.temp_allocator)
	defer destroy_history(&loadedB, context.temp_allocator)
	assert(loadErrorB == .None, "expected second history to remain")
	assert(loadedB[0] == "other project", "expected second history to be unchanged")
	_ = t
}

@(test)
test_load_reports_missing_and_invalid_json :: proc(t: ^testing.T) {
	home, temporaryDirectoryError := os.make_directory_temp(
		"",
		"mimir-history-*",
		context.temp_allocator,
	)
	assert(temporaryDirectoryError == nil, "expected temporary home directory")
	defer os.remove_all(home)

	_, missingError := load(home, "/tmp/missing-project", context.temp_allocator)
	assert(missingError == .Not_Found, "expected missing history file")

	directory := cache_directory(home, context.temp_allocator)
	defer delete(directory, context.temp_allocator)
	assert(os.make_directory_all(directory) == nil, "expected history directory")
	path := project_history_path(home, "/tmp/invalid-project", context.temp_allocator)
	defer delete(path, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(path, "not json") == nil,
		"expected invalid history file to write",
	)
	_, invalidJSONError := load(home, "/tmp/invalid-project", context.temp_allocator)
	assert(invalidJSONError == .Invalid_JSON, "expected invalid JSON error")
	_ = t
}

@(test)
test_invalid_paths_report_invalid_path :: proc(t: ^testing.T) {
	assert(save("", "/tmp/project", nil) == .Invalid_Path, "expected invalid home to reject save")
	assert(clear("/tmp/home", "") == .Invalid_Path, "expected invalid project to reject clear")
	_, loadError := load("", "/tmp/project", context.temp_allocator)
	assert(loadError == .Invalid_Path, "expected invalid home to reject load")
	_ = t
}

@(test)
test_save_reports_io_error :: proc(t: ^testing.T) {
	directory, temporaryDirectoryError := os.make_directory_temp(
		"",
		"mimir-history-file-*",
		context.temp_allocator,
	)
	assert(temporaryDirectoryError == nil, "expected temporary parent directory")
	defer os.remove_all(directory)
	home := strings.concatenate({directory, "/home-file"}, context.temp_allocator)
	defer delete(home, context.temp_allocator)
	assert(os.write_entire_file_from_string(home, "file") == nil, "expected temporary home file")

	history := [1]string{"entry"}
	assert(
		save(home, "/tmp/project", history[:]) == .Io_Error,
		"expected file-backed home to report an I/O error",
	)
	_ = t
}
