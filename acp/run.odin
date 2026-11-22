package acp

import "../ai"
import "../settings"
import "../tool_policy"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The ACP stdio transport: a reader thread for stdin, the main loop, and the writer for
// stdout (ADR-0003, Transport and logging, Main loop and stdin).

ACP_BUSY_WAIT :: 10 * time.Millisecond
ACP_IDLE_WAIT :: 100 * time.Millisecond

// One line from stdin, or a marker for a line that was too long.
Inbound_Line :: struct {
	text:      string,
	oversized: bool,
}

// The stdin reader thread and its queue. The reader owns the queued lines until the main
// thread takes them.
Stdin_Reader :: struct {
	allocator: mem.Allocator,
	file:      ^os.File,
	mutex:     sync.Mutex,
	sema:      sync.Sema,
	lines:     [dynamic]Inbound_Line,
	eof:       bool,
	worker:    ^thread.Thread,
}

// Runs Mimir as an ACP agent on stdin and stdout until stdin ends. It returns the exit status.
run :: proc() -> int {
	// Only the protocol writer writes to stdout. fmt.print* reads os.stdout on every call, so a
	// stray print anywhere in the process goes to stderr. This happens before any thread starts.
	protocolOut := os.stdout
	os.stdout = os.stderr
	context.logger = log.Logger{stderr_logger_proc, nil, .Info, {}}

	home, homeErr := os.user_home_dir(context.allocator)
	if homeErr != nil {
		home = ""
	}
	defer delete(home)
	config := new(settings.Mimir_Config)
	defer free(config)
	configOwned := false
	if home != "" {
		loaded, loadErr := settings.load_config_from_file(home)
		switch loadErr {
		case .None:
			config^ = loaded
			configOwned = true
		case .Not_Found:
			fmt.eprintln("mimir acp: no config file; using the default Ollama config")
		case .Invalid_JSON:
			fmt.eprintln("mimir acp: the config file could not be parsed")
			return 1
		case .Invalid_Home, .Io_Error:
			fmt.eprintln("mimir acp: the config file could not be read")
			return 1
		}
	} else {
		fmt.eprintln("mimir acp: no home directory; using the default Ollama config")
	}
	if !configOwned {
		config^ = settings.default_ollama_config()
	}
	defer if configOwned {
		settings.config_destroy(config)
	} else {
		config_free_default(config)
	}
	register_config_interfaces(config^)
	ai.set_raw_http_log_home(home)

	conn := connection_init(config, home)
	defer connection_destroy(&conn)

	reader: Stdin_Reader
	stdin_reader_start(&reader, os.stdin)
	for {
		lines, eof := stdin_reader_take(&reader)
		for line in lines {
			if line.oversized {
				connection_handle_oversized_line(&conn)
			} else {
				connection_handle_line(&conn, line.text)
			}
			delete(line.text, reader.allocator)
		}
		delete(lines)
		connection_tick(&conn)
		write_outbox(&conn, protocolOut)
		if eof {
			break
		}
		wait := ACP_IDLE_WAIT
		if connection_busy(&conn) {
			wait = ACP_BUSY_WAIT
		}
		_ = sync.sema_wait_with_timeout(&reader.sema, wait)
		free_all(context.temp_allocator)
	}

	connection_shutdown(&conn)
	// The client may have closed its end; write errors are ignored.
	write_outbox(&conn, protocolOut)
	stdin_reader_join(&reader)
	return 0
}

// Frees a default config, whose strings are literals.
config_free_default :: proc(config: ^settings.Mimir_Config) {
	for &grant in config.permissionGrants {
		tool_policy.permission_grant_destroy(&grant)
	}
	delete(config.providers)
	delete(config.disabledSkills)
	delete(config.permissionGrants)
	delete(config.contextWindows)
}

// Registers the AI interface of every enabled provider, as the terminal UI does without its
// Ollama model probe.
register_config_interfaces :: proc(config: settings.Mimir_Config) {
	ai.set_request_timeouts(config.connectTimeoutSeconds, config.stallTimeoutSeconds)
	for provider in config.providers {
		if provider.enabled {
			ai.add_interface(provider.name, provider.type, provider.endpoint)
		}
	}
}

// Writes every outbox line to out, each followed by "\n", and clears the outbox.
write_outbox :: proc(conn: ^Connection, out: ^os.File) {
	for line in conn.outbox {
		_ = write_all(out, transmute([]byte)line)
		_ = write_all(out, []byte{'\n'})
	}
	connection_clear_outbox(conn)
}

write_all :: proc(out: ^os.File, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		written, err := os.write(out, remaining)
		if err != nil || written <= 0 {
			return false
		}
		remaining = remaining[written:]
	}
	return true
}

stderr_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	fmt.eprintfln("mimir acp [%v] %s", level, text)
}

stdin_reader_start :: proc(reader: ^Stdin_Reader, file: ^os.File, allocator := context.allocator) {
	reader.allocator = allocator
	reader.file = file
	reader.lines = make([dynamic]Inbound_Line, 0, 8, allocator)
	reader.worker = thread.create_and_start_with_data(reader, stdin_reader_proc)
}

// Takes the queued lines. The caller owns them and frees their text with reader.allocator. eof
// is true when stdin has ended and every line was taken.
stdin_reader_take :: proc(reader: ^Stdin_Reader) -> (lines: [dynamic]Inbound_Line, eof: bool) {
	sync.mutex_lock(&reader.mutex)
	defer sync.mutex_unlock(&reader.mutex)
	lines = reader.lines
	reader.lines = make([dynamic]Inbound_Line, 0, 8, reader.allocator)
	return lines, reader.eof
}

stdin_reader_join :: proc(reader: ^Stdin_Reader) {
	if reader.worker != nil {
		thread.join(reader.worker)
		thread.destroy(reader.worker)
		reader.worker = nil
	}
	for line in reader.lines {
		delete(line.text, reader.allocator)
	}
	delete(reader.lines)
}

stdin_reader_push :: proc(reader: ^Stdin_Reader, line: Inbound_Line) {
	if sync.mutex_guard(&reader.mutex) {
		append(&reader.lines, line)
	}
	sync.sema_post(&reader.sema)
}

// Reads stdin, splits it on "\n" and queues each line. A line longer than
// ACP_MAX_MESSAGE_BYTES is skipped up to its "\n" and queued as an oversized marker.
stdin_reader_proc :: proc(data: rawptr) {
	reader := cast(^Stdin_Reader)data
	pending := make([dynamic]byte, 0, 64 * 1024, reader.allocator)
	defer delete(pending)
	skipping := false
	buffer: [64 * 1024]byte
	for {
		count, readErr := os.read(reader.file, buffer[:])
		if count > 0 {
			chunk := buffer[:count]
			for len(chunk) > 0 {
				newline := -1
				for b, index in chunk {
					if b == '\n' {
						newline = index
						break
					}
				}
				if newline < 0 {
					if !skipping {
						append(&pending, ..chunk)
						if len(pending) > ACP_MAX_MESSAGE_BYTES {
							skipping = true
							clear(&pending)
						}
					}
					break
				}
				if skipping {
					skipping = false
					stdin_reader_push(reader, Inbound_Line{oversized = true})
				} else {
					append(&pending, ..chunk[:newline])
					if len(pending) > ACP_MAX_MESSAGE_BYTES {
						stdin_reader_push(reader, Inbound_Line{oversized = true})
					} else {
						text := strings.trim_right(string(pending[:]), "\r")
						stdin_reader_push(
							reader,
							Inbound_Line{text = strings.clone(text, reader.allocator)},
						)
					}
					clear(&pending)
				}
				chunk = chunk[newline + 1:]
			}
		}
		if readErr != nil || count <= 0 {
			break
		}
	}
	// A last line without "\n" still counts.
	if !skipping && len(pending) > 0 {
		text := strings.trim_right(string(pending[:]), "\r")
		stdin_reader_push(reader, Inbound_Line{text = strings.clone(text, reader.allocator)})
	}
	if sync.mutex_guard(&reader.mutex) {
		reader.eof = true
	}
	sync.sema_post(&reader.sema)
}
