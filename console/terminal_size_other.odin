#+build !windows
#+build !linux
package console

@(private)
_terminal_size :: proc() -> (Terminal_Size, bool) {
	return Terminal_Size{}, false
}
