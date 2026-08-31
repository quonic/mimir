package console

import "core:sys/windows"

@(private)
_terminal_size :: proc() -> (Terminal_Size, bool) {
	handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
	if handle == windows.INVALID_HANDLE || handle == nil {
		return Terminal_Size{}, false
	}
	info: windows.CONSOLE_SCREEN_BUFFER_INFO
	if !windows.GetConsoleScreenBufferInfo(handle, &info) {
		return Terminal_Size{}, false
	}
	columns := int(info.srWindow.Right) - int(info.srWindow.Left) + 1
	rows := int(info.srWindow.Bottom) - int(info.srWindow.Top) + 1
	if rows <= 0 || columns <= 0 {
		return Terminal_Size{}, false
	}
	return Terminal_Size{rows = rows, columns = columns}, true
}
