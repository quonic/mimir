package ai

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_raw_http_log_path_with_home :: proc(t: ^testing.T) {
	path := raw_http_log_path_with_home("/tmp/mimir-home", context.temp_allocator)
	assert(
		path == "/tmp/mimir-home/.cache/mimir/last_session.log",
		"expected raw HTTP log path under home cache directory",
	)
	_ = t
}

@(test)
test_set_raw_http_log_home_owns_configured_home :: proc(t: ^testing.T) {
	set_raw_http_log_home("")
	home := strings.clone("/tmp/mimir-owned-home", context.temp_allocator)
	defer delete(home, context.temp_allocator)

	set_raw_http_log_home(home)
	defer set_raw_http_log_home("")

	assert(rawHTTPLogHome == home, "expected configured raw HTTP log home")
	assert(raw_data(rawHTTPLogHome) != raw_data(home), "expected raw HTTP log home to be owned")
	_ = t
}

@(test)
test_raw_http_log_begin_overwrites_and_append_extends :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-log-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	assert(raw_http_log_begin_with_home(home, "http://one"), "expected first log begin")
	assert(raw_http_log_append_with_home(home, "first chunk\n"), "expected append")
	assert(raw_http_log_begin_with_home(home, "http://two"), "expected second log begin")
	assert(raw_http_log_append_with_home(home, "second chunk\n"), "expected second append")

	path := raw_http_log_path_with_home(home, context.temp_allocator)
	data, readErr := os.read_entire_file(path, context.temp_allocator)
	assert(readErr == nil, "expected raw HTTP log file to be readable")
	logText := string(data)

	assert(
		logText == "mimir raw http session\ntarget: http://two\n\nsecond chunk\n",
		"expected latest log content only",
	)
	_ = t
}
