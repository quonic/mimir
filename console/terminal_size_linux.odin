package console

import "core:os"
import "core:sys/linux"

Linux_Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

@(private)
_terminal_size :: proc() -> (Terminal_Size, bool) {
	window: Linux_Winsize
	fd := linux.Fd(os.fd(os.stdout))
	result := linux.ioctl(fd, linux.TIOCGWINSZ, uintptr(rawptr(&window)))
	if result != 0 || window.ws_row == 0 || window.ws_col == 0 {
		return Terminal_Size{}, false
	}
	return Terminal_Size{rows = int(window.ws_row), columns = int(window.ws_col)}, true
}
