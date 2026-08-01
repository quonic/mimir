package text_input

import "core:testing"

@(test)
test_input_buffer_tracks_multiline_text :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "first\nsecond")
	assert(input_buffer_line_count(&buffer) == 2, "expected newline to expand input lines")
	assert(
		input_buffer_string(&buffer) == "first\nsecond",
		"expected input buffer to preserve pasted text",
	)

	assert(input_buffer_backspace(&buffer), "expected backspace to remove trailing byte")
	assert(input_buffer_string(&buffer) == "first\nsecon", "expected backspace to update text")
	assert(
		input_buffer_cursor_position(&buffer) == len(input_buffer_string(&buffer)),
		"expected cursor to remain at end after trailing backspace",
	)

	submitted := input_buffer_submit(&buffer, context.temp_allocator)
	assert(submitted == "first\nsecon", "expected submitted text to match input")
	assert(input_buffer_string(&buffer) == "", "expected submit to clear input")
	assert(input_buffer_cursor_position(&buffer) == 0, "expected submit to reset cursor")
	_ = t
}

@(test)
test_input_buffer_replaces_and_deletes_grapheme_selection :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "aébc")
	input_buffer_extend_selection_to(&buffer, 1)
	assert(input_buffer_has_selection(&buffer), "expected selection after extending from end")
	assert(input_buffer_selection_text(&buffer) == "ébc", "expected selected UTF-8 graphemes")

	input_buffer_push_text(&buffer, "X")
	assert(input_buffer_string(&buffer) == "aX", "expected inserted text to replace selection")
	assert(!input_buffer_has_selection(&buffer), "expected replacement to clear selection")

	input_buffer_select_all(&buffer)
	assert(input_buffer_backspace(&buffer), "expected backspace to delete the selection")
	assert(input_buffer_string(&buffer) == "", "expected selection deletion to clear text")
	assert(
		input_buffer_cursor_position(&buffer) == 0,
		"expected selection deletion to place cursor at start",
	)
	_ = t
}

@(test)
test_input_buffer_inserts_and_backspaces_at_cursor :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "ab")
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move left")
	input_buffer_push_byte(&buffer, 'X')

	assert(input_buffer_string(&buffer) == "aXb", "expected insertion at cursor")
	assert(input_buffer_cursor_position(&buffer) == 2, "expected cursor after inserted byte")
	assert(input_buffer_backspace(&buffer), "expected backspace before cursor")
	assert(input_buffer_string(&buffer) == "ab", "expected backspace to remove inserted byte")
	assert(
		input_buffer_cursor_position(&buffer) == 1,
		"expected cursor to move left after backspace",
	)
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move to start")
	assert(!input_buffer_move_cursor_left(&buffer), "expected left movement to stop at start")
	assert(!input_buffer_backspace(&buffer), "expected backspace at start to do nothing")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move right")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move to end")
	assert(!input_buffer_move_cursor_right(&buffer), "expected right movement to stop at end")
	_ = t
}

@(test)
test_input_buffer_moves_to_start_and_deletes_at_cursor :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "aéx")
	input_buffer_move_cursor_start(&buffer)
	assert(input_buffer_cursor_position(&buffer) == 0, "expected cursor at input start")
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove first grapheme")
	assert(
		input_buffer_string(&buffer) == "éx",
		"expected delete to preserve multi-byte grapheme",
	)
	assert(input_buffer_cursor_position(&buffer) == 0, "expected delete to retain cursor position")
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove multi-byte grapheme")
	assert(input_buffer_string(&buffer) == "x", "expected complete multi-byte grapheme removal")

	input_buffer_set_text(&buffer, "éx")
	input_buffer_move_cursor_start(&buffer)
	assert(input_buffer_delete_at_cursor(&buffer), "expected delete to remove combining grapheme")
	assert(
		input_buffer_string(&buffer) == "x",
		"expected delete to retain combining grapheme integrity",
	)
	input_buffer_move_cursor_end(&buffer)
	assert(!input_buffer_delete_at_cursor(&buffer), "expected delete at end to do nothing")
	_ = t
}

@(test)
test_input_buffer_handles_multibyte_graphemes :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "café")
	assert(input_buffer_cursor_position(&buffer) == 4, "expected cursor to count graphemes")
	assert(input_buffer_move_cursor_left(&buffer), "expected cursor to move left over é")
	input_buffer_push_text(&buffer, "X")

	assert(input_buffer_string(&buffer) == "cafXé", "expected insertion before full é grapheme")
	assert(input_buffer_backspace(&buffer), "expected backspace to remove inserted text")
	assert(input_buffer_string(&buffer) == "café", "expected backspace to preserve UTF-8 text")
	assert(input_buffer_move_cursor_right(&buffer), "expected cursor to move right over é")
	assert(input_buffer_backspace(&buffer), "expected backspace to remove full é grapheme")
	assert(input_buffer_string(&buffer) == "caf", "expected full multi-byte grapheme removal")
	_ = t
}

@(test)
test_input_buffer_handles_combining_graphemes :: proc(t: ^testing.T) {
	buffer := input_buffer_init(context.temp_allocator)
	defer input_buffer_destroy(&buffer)

	input_buffer_push_text(&buffer, "é")
	assert(
		input_buffer_cursor_position(&buffer) == 1,
		"expected combining mark to share cursor cell",
	)
	assert(input_buffer_backspace(&buffer), "expected backspace to remove combined grapheme")
	assert(input_buffer_string(&buffer) == "", "expected combining grapheme to be removed at once")
	assert(input_buffer_cursor_position(&buffer) == 0, "expected cursor to return to start")
	_ = t
}
