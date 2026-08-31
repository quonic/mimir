package console

Terminal_Size :: struct {
	rows:    int,
	columns: int,
}

terminal_size :: proc() -> (Terminal_Size, bool) {
	return _terminal_size()
}
