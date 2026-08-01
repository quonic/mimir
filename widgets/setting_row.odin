package widgets

import "core:strings"

setting_row_checkbox :: proc(
	label: string,
	checked: bool,
	allocator := context.allocator,
) -> string {
	marker := "[ ] "
	if checked {
		marker = "[x] "
	}
	return strings.concatenate({marker, label}, allocator)
}

setting_row_button :: proc(label: string, allocator := context.allocator) -> string {
	return strings.concatenate({"[ ", label, " ]"}, allocator)
}

setting_row_choice :: proc(label, value: string, allocator := context.allocator) -> string {
	return strings.concatenate({label, ": < ", value, " >"}, allocator)
}

setting_row_option :: proc(
	label: string,
	selected: bool,
	allocator := context.allocator,
) -> string {
	marker := "  "
	if selected {
		marker = "* "
	}
	return strings.concatenate({marker, label}, allocator)
}
