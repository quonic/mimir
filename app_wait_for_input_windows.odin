package main

import "core:sys/windows"

app_wait_for_input :: proc(timeout_ms: int) -> (ready, ok: bool) {
	handle := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	switch windows.WaitForSingleObject(handle, windows.DWORD(timeout_ms)) {
	case windows.WAIT_OBJECT_0:
		return true, true
	case windows.WAIT_TIMEOUT:
		return false, true
	case:
		return false, false
	}
}
