package mcp

import "core:c"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

MCP_IO_TIMEOUT_MS :: 30_000

// Stdio_Transport spawns an MCP server as a subprocess and exchanges
// newline-delimited JSON-RPC messages over its stdin/stdout, per
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.
Stdio_Transport :: struct {
	process:       os.Process,
	stdinWrite:    ^os.File,
	stdoutRead:    ^os.File,
	pending:       [dynamic]byte,
	responses:     [dynamic]Stdio_Response,
	notifications: [dynamic]string,
	alive:         bool,
	allocator:     mem.Allocator,
}

Stdio_Response :: struct {
	id:  int,
	raw: string,
}

stdio_transport_clear_messages :: proc(t: ^Stdio_Transport) {
	for response in t.responses {
		delete(response.raw, t.allocator)
	}
	delete(t.responses)
	for notification in t.notifications {
		delete(notification, t.allocator)
	}
	delete(t.notifications)
}

stdio_transport_start :: proc(
	command: string,
	args: []string,
	allocator := context.allocator,
) -> (
	Stdio_Transport,
	bool,
) {
	if command == "" {
		return Stdio_Transport{}, false
	}

	stdinRead, stdinWrite, stdinErr := os.pipe()
	if stdinErr != nil {
		return Stdio_Transport{}, false
	}
	stdoutRead, stdoutWrite, stdoutErr := os.pipe()
	if stdoutErr != nil {
		os.close(stdinRead)
		os.close(stdinWrite)
		return Stdio_Transport{}, false
	}

	fullCommand := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&fullCommand, command)
	for arg in args {
		append(&fullCommand, arg)
	}

	desc := os.Process_Desc {
		command = fullCommand[:],
		stdin   = stdinRead,
		stdout  = stdoutWrite,
	}
	process, startErr := os.process_start(desc)
	os.close(stdinRead)
	os.close(stdoutWrite)
	if startErr != nil {
		os.close(stdinWrite)
		os.close(stdoutRead)
		return Stdio_Transport{}, false
	}

	return Stdio_Transport {
			process = process,
			stdinWrite = stdinWrite,
			stdoutRead = stdoutRead,
			pending = make([dynamic]byte, 0, 4096, allocator),
			responses = make([dynamic]Stdio_Response, 0, 8, allocator),
			notifications = make([dynamic]string, 0, 8, allocator),
			alive = true,
			allocator = allocator,
		},
		true
}

// Routes one complete JSON-RPC message into the response or notification queue.
// The queued raw text is owned by the transport and survives caller cleanup.
stdio_transport_route_message :: proc(t: ^Stdio_Transport, raw: string) -> bool {
	value, err := json.parse_string(raw, parse_integers = true, allocator = context.temp_allocator)
	if err != .None {
		return false
	}
	defer json.destroy_value(value, context.temp_allocator)
	object, objectOK := value.(json.Object)
	if !objectOK {
		return false
	}
	if id, hasID := object["id"].(json.Integer); hasID {
		append(&t.responses, Stdio_Response{id = int(id), raw = strings.clone(raw, t.allocator)})
		return true
	}
	if _, hasMethod := object["method"].(json.String); hasMethod {
		append(&t.notifications, strings.clone(raw, t.allocator))
		return true
	}
	return false
}

stdio_transport_take_response :: proc(t: ^Stdio_Transport, id: int) -> (string, bool) {
	for response, index in t.responses {
		if response.id != id {
			continue
		}
		raw := response.raw
		t.responses[index].raw = ""
		ordered_remove(&t.responses, index)
		return raw, true
	}
	return "", false
}

stdio_transport_take_notification :: proc(t: ^Stdio_Transport) -> (string, bool) {
	if len(t.notifications) == 0 {
		return "", false
	}
	raw := t.notifications[0]
	t.notifications[0] = ""
	ordered_remove(&t.notifications, 0)
	return raw, true
}

// Writes one JSON-RPC message line (request or notification) to the server's stdin.
stdio_transport_write_line :: proc(t: ^Stdio_Transport, line: string) -> bool {
	if !t.alive {
		return false
	}
	payload := strings.concatenate({line, "\n"}, context.temp_allocator)
	remaining := transmute([]byte)payload
	for len(remaining) > 0 {
		written, err := os.write(t.stdinWrite, remaining)
		if err != nil || written <= 0 {
			t.alive = false
			return false
		}
		remaining = remaining[written:]
	}
	return true
}

// Reads the next newline-delimited message from the server's stdout. Blocks
// until a full line is available, the process closes stdout, or a read error
// occurs. A timeout marks the transport unavailable so callers can re-probe.
stdio_transport_read_line :: proc(
	t: ^Stdio_Transport,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if !t.alive {
		return "", false
	}
	for {
		for index := 0; index < len(t.pending); index += 1 {
			if t.pending[index] == '\n' {
				line := strings.clone(string(t.pending[:index]), allocator)
				remainderLength := len(t.pending) - index - 1
				remainder := make([dynamic]byte, remainderLength, t.allocator)
				copy(remainder[:], t.pending[index + 1:])
				delete(t.pending)
				t.pending = remainder
				return line, true
			}
		}
		fds := [1]posix.pollfd {
			{fd = posix.FD(os.fd(t.stdoutRead)), events = posix.Poll_Event{.IN}},
		}
		pollResult := posix.poll(
			raw_data(fds[:]),
			posix.nfds_t(len(fds)),
			c.int(MCP_IO_TIMEOUT_MS),
		)
		if pollResult <= 0 || .IN not_in fds[0].revents {
			t.alive = false
			return "", false
		}
		buf: [4096]byte
		read, err := os.read(t.stdoutRead, buf[:])
		if err != nil || read == 0 {
			t.alive = false
			return "", false
		}
		append(&t.pending, ..buf[:read])
	}
}

// Shuts down the subprocess per the spec: close stdin, wait briefly, then kill
// if it hasn't exited.
stdio_transport_close :: proc(t: ^Stdio_Transport) {
	if t.stdinWrite != nil {
		os.close(t.stdinWrite)
	}
	if t.process.pid != 0 {
		_, waitErr := os.process_wait(t.process, 2 * time.Second)
		if waitErr != nil {
			_ = os.process_kill(t.process)
			_, _ = os.process_wait(t.process)
		}
	}
	if t.stdoutRead != nil {
		os.close(t.stdoutRead)
	}
	delete(t.pending)
	stdio_transport_clear_messages(t)
	t^ = {}
}
