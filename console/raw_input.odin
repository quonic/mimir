package console

import "core:os"
import "core:sys/posix"
import "core:terminal"

Raw_Terminal_State :: struct {
	fd:       posix.FD,
	original: posix.termios,
	active:   bool,
}

Mouse_Input_Result :: enum int {
	None = 0,
	Quit,
	Mouse_Sequence,
}

Mouse_Input_Buffer :: struct {
	pending:     [256]byte,
	pending_len: int,
}

enable_raw_input_mode :: proc() -> (Raw_Terminal_State, bool) {
	state: Raw_Terminal_State
	if !terminal.is_terminal(os.stdin) {
		return state, false
	}

	state.fd = posix.FD(os.fd(os.stdin))
	if posix.tcgetattr(state.fd, &state.original) != .OK {
		return Raw_Terminal_State{}, false
	}

	raw := state.original
	raw.c_lflag -= {.ICANON, .ECHO, .ISIG}
	raw.c_iflag -= {.ICRNL, .IXON}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(state.fd, .TCSANOW, &raw) != .OK {
		return Raw_Terminal_State{}, false
	}
	_ = posix.tcflush(state.fd, .TCIFLUSH)
	state.active = true
	return state, true
}

restore_raw_input_mode :: proc(state: ^Raw_Terminal_State) {
	if state == nil || !state.active {
		return
	}
	_ = posix.tcsetattr(state.fd, .TCSANOW, &state.original)
	state.active = false
}

mouse_input_reset :: proc(buffer: ^Mouse_Input_Buffer) {
	buffer.pending_len = 0
}

mouse_input_push_byte :: proc(
	buffer: ^Mouse_Input_Buffer,
	input: byte,
) -> (
	Mouse_Input_Result,
	string,
) {
	if buffer.pending_len == 0 {
		switch input {
		case 'q', 'Q':
			return .Quit, ""
		case 0x1b:
			buffer.pending[0] = input
			buffer.pending_len = 1
			return .None, ""
		case:
			return .None, ""
		}
	}

	if buffer.pending_len >= len(buffer.pending) {
		mouse_input_reset(buffer)
		return .None, ""
	}

	buffer.pending[buffer.pending_len] = input
	buffer.pending_len += 1

	sequence, complete, invalid := mouse_input_try_extract_sequence(buffer)
	if invalid {
		mouse_input_reset(buffer)
		return .None, ""
	}
	if complete {
		mouse_input_reset(buffer)
		return .Mouse_Sequence, sequence
	}
	return .None, ""
}

@(private)
mouse_input_try_extract_sequence :: proc(buffer: ^Mouse_Input_Buffer) -> (string, bool, bool) {
	if buffer.pending_len <= 0 {
		return "", false, false
	}
	if buffer.pending[0] != 0x1b {
		return "", false, true
	}
	if buffer.pending_len == 1 {
		return "", false, false
	}
	if buffer.pending[1] != '[' {
		return "", false, true
	}
	if buffer.pending_len == 2 {
		return "", false, false
	}
	if buffer.pending[2] != '<' {
		return "", false, true
	}

	for index := 3; index < buffer.pending_len; index += 1 {
		ch := buffer.pending[index]
		switch {
		case ch >= '0' && ch <= '9':
			continue
		case ch == ';':
			continue
		case (ch == 'M' || ch == 'm') && index == buffer.pending_len - 1:
			return string(buffer.pending[:buffer.pending_len]), true, false
		case:
			return "", false, true
		}
	}

	return "", false, false
}
