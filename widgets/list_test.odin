package widgets

import console "../console"
import "core:strings"
import "core:testing"

@(test)
test_list_cursor_after_move_wraps :: proc(t: ^testing.T) {
	assert(list_cursor_after_move(0, 3, -1) == 2, "expected cursor to wrap backward")
	assert(list_cursor_after_move(2, 3, 1) == 0, "expected cursor to wrap forward")
	assert(list_cursor_after_move(0, 0, 1) == 0, "expected empty list cursor to stay zero")
	_ = t
}

@(test)
test_list_render_marks_focus_and_selection :: proc(t: ^testing.T) {
	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	labels := [2]string{"First", "Second"}
	list_render(
		&batch,
		console.Region{top_row = 1, left_column = 1, bottom_row = 2, right_column = 20},
		labels[:],
		List_Render_Options {
			cursorIndex = 1,
			selectedIndex = 0,
			focused = true,
			showSelectedMarker = true,
		},
	)

	sequence := console.batch_sequence(&batch)
	assert(strings.contains(sequence, "* First"), "expected selected row marker")
	assert(strings.contains(sequence, "> Second"), "expected focused cursor marker")
	_ = t
}
