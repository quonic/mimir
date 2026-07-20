package console

import "core:os"
import "core:sys/linux"

Terminal_Size :: struct {
	rows:    int,
	columns: int,
}

terminal_size :: proc() -> (Terminal_Size, bool) {
	return terminal_size_for_fd(linux.Fd(os.fd(os.stdout)))
}

terminal_size_for_fd :: proc(fd: linux.Fd) -> (Terminal_Size, bool) {
	when ODIN_OS == .Linux {
		window: Linux_Winsize
		result := linux.ioctl(fd, linux.TIOCGWINSZ, uintptr(rawptr(&window)))
		if result != 0 || window.ws_row == 0 || window.ws_col == 0 {
			return Terminal_Size{}, false
		}
		return Terminal_Size{rows = int(window.ws_row), columns = int(window.ws_col)}, true
	}

	return Terminal_Size{}, false
}

Linux_Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}