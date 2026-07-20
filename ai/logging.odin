package ai

import "core:os"
import "core:strings"

RAW_HTTP_LOG_DIR :: "/.cache/mimir"
RAW_HTTP_LOG_FILE :: "/last_session.log"

rawHTTPLogHome: string

set_raw_http_log_home :: proc(home: string) {
	rawHTTPLogHome = home
}

raw_http_log_dir_with_home :: proc(home: string, allocator := context.allocator) -> string {
	if home == "" {
		return ""
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, home)
	strings.write_string(&builder, RAW_HTTP_LOG_DIR)
	return strings.to_string(builder)
}

raw_http_log_path_with_home :: proc(home: string, allocator := context.allocator) -> string {
	dir := raw_http_log_dir_with_home(home, allocator)
	if dir == "" {
		return ""
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, dir)
	strings.write_string(&builder, RAW_HTTP_LOG_FILE)
	return strings.to_string(builder)
}

raw_http_log_home :: proc() -> (string, bool) {
	if rawHTTPLogHome != "" {
		return rawHTTPLogHome, true
	}

	home, err := os.user_home_dir(context.temp_allocator)
	return home, err == nil && home != ""
}

raw_http_log_ensure_dir :: proc(home: string) -> bool {
	dir := raw_http_log_dir_with_home(home, context.temp_allocator)
	if dir == "" {
		return false
	}

	if os.exists(dir) {
		return true
	}

	return os.make_directory_all(dir) == nil
}

raw_http_log_begin :: proc(target: string) -> bool {
	home, ok := raw_http_log_home()
	if !ok {
		return false
	}
	return raw_http_log_begin_with_home(home, target)
}

raw_http_log_begin_with_home :: proc(home: string, target: string) -> bool {
	if !raw_http_log_ensure_dir(home) {
		return false
	}

	path := raw_http_log_path_with_home(home, context.temp_allocator)
	if path == "" {
		return false
	}

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, "mimir raw http session\n")
	strings.write_string(&builder, "target: ")
	strings.write_string(&builder, target)
	strings.write_string(&builder, "\n\n")

	return os.write_entire_file(path, strings.to_string(builder)) == nil
}

raw_http_log_append :: proc(text: string) -> bool {
	home, ok := raw_http_log_home()
	if !ok {
		return false
	}
	return raw_http_log_append_with_home(home, text)
}

raw_http_log_append_with_home :: proc(home: string, text: string) -> bool {
	if text == "" {
		return true
	}
	if !raw_http_log_ensure_dir(home) {
		return false
	}

	path := raw_http_log_path_with_home(home, context.temp_allocator)
	if path == "" {
		return false
	}

	file, openErr := os.open(
		path,
		os.O_WRONLY | os.O_CREATE | os.O_APPEND,
		os.Permissions_Read_All + {.Write_User},
	)
	if openErr != nil {
		return false
	}
	defer os.close(file)

	written, writeErr := os.write(file, transmute([]byte)text)
	return writeErr == nil && written == len(text)
}
