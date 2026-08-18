package mcp

import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// Stdio_Transport spawns an MCP server as a subprocess and exchanges
// newline-delimited JSON-RPC messages over its stdin/stdout, per
// https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.
Stdio_Transport :: struct {
	process:    os.Process,
	stdinWrite: ^os.File,
	stdoutRead: ^os.File,
	pending:    [dynamic]byte,
	alive:      bool,
	allocator:  mem.Allocator,
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
			alive = true,
			allocator = allocator,
		},
		true
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
// occurs. The stdio transport has no per-request timeout in this pass; callers
// that need one should wrap this call in a separate goroutine/thread with a
// deadline.
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
	t^ = {}
}
