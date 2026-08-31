#+build !windows
package console

import "core:os"
import "core:sys/posix"
import "core:terminal"

Raw_Terminal_State :: struct {
	active:   bool,
	fd:       posix.FD,
	original: posix.termios,
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
