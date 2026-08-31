package console

import "core:os"
import "core:sys/windows"
import "core:terminal"

// SetConsoleMode requires this bit set before ENABLE_QUICK_EDIT_MODE changes take effect.
@(private)
WINDOWS_ENABLE_EXTENDED_FLAGS :: windows.DWORD(0x0080)

Raw_Terminal_State :: struct {
	active:        bool,
	stdin_handle:  windows.HANDLE,
	stdout_handle: windows.HANDLE,
	original_in:   windows.DWORD,
	original_out:  windows.DWORD,
}

enable_raw_input_mode :: proc() -> (Raw_Terminal_State, bool) {
	state: Raw_Terminal_State
	if !terminal.is_terminal(os.stdin) {
		return state, false
	}

	state.stdin_handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	state.stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
	if state.stdin_handle == windows.INVALID_HANDLE ||
	   state.stdin_handle == nil ||
	   state.stdout_handle == windows.INVALID_HANDLE ||
	   state.stdout_handle == nil {
		return Raw_Terminal_State{}, false
	}
	if !windows.GetConsoleMode(state.stdin_handle, &state.original_in) ||
	   !windows.GetConsoleMode(state.stdout_handle, &state.original_out) {
		return Raw_Terminal_State{}, false
	}

	// Drop line editing, echo, signals, and mouse/window/QuickEdit input records so
	// WaitForSingleObject only wakes app_wait_for_input for actual key bytes.
	raw_in :=
		state.original_in &
		~(windows.ENABLE_LINE_INPUT |
				windows.ENABLE_ECHO_INPUT |
				windows.ENABLE_PROCESSED_INPUT |
				windows.ENABLE_MOUSE_INPUT |
				windows.ENABLE_WINDOW_INPUT |
				windows.ENABLE_QUICK_EDIT_MODE)
	raw_in |= windows.ENABLE_VIRTUAL_TERMINAL_INPUT | WINDOWS_ENABLE_EXTENDED_FLAGS
	if !windows.SetConsoleMode(state.stdin_handle, raw_in) {
		return Raw_Terminal_State{}, false
	}

	// Best-effort: needed for ANSI sequences on cmd.exe; Windows Terminal has it on already.
	_ = windows.SetConsoleMode(
		state.stdout_handle,
		state.original_out |
		windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
		windows.ENABLE_PROCESSED_OUTPUT,
	)

	state.active = true
	return state, true
}

restore_raw_input_mode :: proc(state: ^Raw_Terminal_State) {
	if state == nil || !state.active {
		return
	}
	_ = windows.SetConsoleMode(state.stdin_handle, state.original_in)
	_ = windows.SetConsoleMode(state.stdout_handle, state.original_out)
	state.active = false
}
