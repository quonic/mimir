package console

import "core:io"
import "core:strings"
import "core:testing"

capture_write :: proc(sequence: string) -> (string, io.Error) {
	buffer: [256]byte
	builder := strings.builder_from_bytes(buffer[:])
	_, err := write(sequence, strings.to_writer(&builder))
	return strings.clone(strings.to_string(builder), context.temp_allocator), err
}

assert_sequence :: proc(t: ^testing.T, actual, expected, message: string) {
	assert(actual == expected, message)
	_ = t
}

assert_written_sequence :: proc(
	t: ^testing.T,
	sequence, expected, write_message, sequence_message: string,
) {
	captured, err := capture_write(sequence)
	assert(err == nil, write_message)
	assert(captured == expected, sequence_message)
	_ = t
}

@(test)
test_cursor_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		cursor_up_sequence(),
		"\x1b[1A",
		"expected cursor_up_sequence default to move one row",
	)
	assert_sequence(
		t,
		cursor_down_sequence(3),
		"\x1b[3B",
		"expected cursor_down_sequence to encode row count",
	)
	assert_sequence(
		t,
		cursor_right_sequence(0),
		"\x1b[1C",
		"expected cursor_right_sequence to clamp to one column",
	)
	assert_sequence(
		t,
		cursor_left_sequence(2),
		"\x1b[2D",
		"expected cursor_left_sequence to encode column count",
	)
	assert_sequence(
		t,
		cursor_goto_sequence(4, 9),
		"\x1b[4;9H",
		"expected cursor_goto_sequence to encode row and column",
	)
	assert_sequence(
		t,
		cursor_home_sequence(),
		"\x1b[1;1H",
		"expected cursor_home_sequence to move to 1,1",
	)
	assert_sequence(
		t,
		cursor_to_row_sequence(-2),
		"\x1b[1d",
		"expected cursor_to_row_sequence to clamp to one-based coordinates",
	)
	assert_sequence(
		t,
		cursor_to_column_sequence(-5),
		"\x1b[1G",
		"expected cursor_to_column_sequence to clamp to one-based coordinates",
	)
	assert_sequence(
		t,
		cursor_save_sequence(),
		"\x1b[s",
		"expected cursor_save_sequence to use CSI s",
	)
	assert_sequence(
		t,
		cursor_restore_sequence(),
		"\x1b[u",
		"expected cursor_restore_sequence to use CSI u",
	)
	assert_sequence(
		t,
		cursor_hide_sequence(),
		"\x1b[?25l",
		"expected cursor_hide_sequence to hide the cursor",
	)
	assert_sequence(
		t,
		cursor_show_sequence(),
		"\x1b[?25h",
		"expected cursor_show_sequence to show the cursor",
	)
	assert_written_sequence(
		t,
		cursor_up_sequence(2),
		"\x1b[2A",
		"expected cursor sequence write to succeed",
		"expected cursor sequence write to preserve the exact bytes",
	)
}

@(test)
test_display_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		set_insert_mode_sequence(true),
		"\x1b[4h",
		"expected set_insert_mode_sequence(true) to enable insert mode",
	)
	assert_sequence(
		t,
		set_insert_mode_sequence(false),
		"\x1b[4l",
		"expected set_insert_mode_sequence(false) to disable insert mode",
	)
	assert_sequence(
		t,
		set_autowrap_sequence(true),
		"\x1b[?7h",
		"expected set_autowrap_sequence(true) to enable autowrap",
	)
	assert_sequence(
		t,
		set_autowrap_sequence(false),
		"\x1b[?7l",
		"expected set_autowrap_sequence(false) to disable autowrap",
	)
	assert_sequence(
		t,
		set_reverse_video_mode_sequence(true),
		"\x1b[?5h",
		"expected set_reverse_video_mode_sequence(true) to enable reverse video mode",
	)
	assert_sequence(
		t,
		set_reverse_video_mode_sequence(false),
		"\x1b[?5l",
		"expected set_reverse_video_mode_sequence(false) to disable reverse video mode",
	)
	assert_sequence(
		t,
		set_scroll_region_sequence(2, 8),
		"\x1b[2;8r",
		"expected set_scroll_region_sequence to encode top and bottom rows",
	)
	assert_sequence(
		t,
		set_scroll_region_sequence(8, 2),
		"\x1b[8;8r",
		"expected set_scroll_region_sequence to clamp the bottom row to the top row",
	)
	assert_sequence(
		t,
		reset_scroll_region_sequence(),
		"\x1b[r",
		"expected reset_scroll_region_sequence to reset the scrolling region",
	)
	assert_sequence(
		t,
		enter_alternate_screen_sequence(),
		"\x1b[?1049h",
		"expected enter_alternate_screen_sequence to enable alternate buffer",
	)
	assert_sequence(
		t,
		exit_alternate_screen_sequence(),
		"\x1b[?1049l",
		"expected exit_alternate_screen_sequence to disable alternate buffer",
	)
	assert_sequence(
		t,
		begin_synchronized_update_sequence(),
		"\x1b[?2026h",
		"expected synchronized update start to enable DEC mode 2026",
	)
	assert_sequence(
		t,
		end_synchronized_update_sequence(),
		"\x1b[?2026l",
		"expected synchronized update end to disable DEC mode 2026",
	)
	assert_sequence(
		t,
		synchronized_output_sequence("frame"),
		"\x1b[?2026hframe\x1b[?2026l",
		"expected synchronized output to bracket a complete frame",
	)
	assert_sequence(
		t,
		terminal_app_start_sequence(),
		"\x1b[?1049h\x1b[?25l\x1b[2J\x1b[1;1H",
		"expected terminal_app_start_sequence to enter the app screen cleanly",
	)
	assert_sequence(
		t,
		terminal_app_stop_sequence(),
		"\x1b[?2026l\x1b[0m\x1b[?25h\x1b[?1049l",
		"expected terminal_app_stop_sequence to restore terminal display state",
	)
	assert_written_sequence(
		t,
		set_autowrap_sequence(false),
		"\x1b[?7l",
		"expected display mode sequence write to succeed",
		"expected display mode sequence write to preserve the exact bytes",
	)
}

@(test)
test_erase_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		clear_screen_sequence(),
		"\x1b[2J",
		"expected clear_screen_sequence to erase the whole display",
	)
	assert_sequence(
		t,
		clear_scrollback_sequence(),
		"\x1b[3J",
		"expected clear_scrollback_sequence to erase scrollback",
	)
	assert_sequence(
		t,
		clear_to_end_of_screen_sequence(),
		"\x1b[J",
		"expected clear_to_end_of_screen_sequence to use default ED",
	)
	assert_sequence(
		t,
		clear_to_start_of_screen_sequence(),
		"\x1b[1J",
		"expected clear_to_start_of_screen_sequence to erase from start through cursor",
	)
	assert_sequence(
		t,
		clear_line_sequence(),
		"\x1b[2K",
		"expected clear_line_sequence to erase the whole line",
	)
	assert_sequence(
		t,
		clear_to_start_of_line_sequence(),
		"\x1b[1K",
		"expected clear_to_start_of_line_sequence to erase from line start through cursor",
	)
	assert_sequence(
		t,
		clear_to_end_of_line_sequence(),
		"\x1b[K",
		"expected clear_to_end_of_line_sequence to use default EL",
	)
	assert_sequence(
		t,
		clear_screen_home_sequence(),
		"\x1b[2J\x1b[1;1H",
		"expected clear_screen_home_sequence to clear the screen and move home",
	)
	assert_sequence(
		t,
		insert_characters_sequence(),
		"\x1b[1@",
		"expected insert_characters_sequence default to insert one character",
	)
	assert_sequence(
		t,
		delete_characters_sequence(3),
		"\x1b[3P",
		"expected delete_characters_sequence to encode the delete count",
	)
	assert_sequence(
		t,
		erase_characters_sequence(0),
		"\x1b[1X",
		"expected erase_characters_sequence to clamp the count to one",
	)
	assert_sequence(
		t,
		insert_lines_sequence(2),
		"\x1b[2L",
		"expected insert_lines_sequence to encode the line count",
	)
	assert_sequence(
		t,
		delete_lines_sequence(4),
		"\x1b[4M",
		"expected delete_lines_sequence to encode the line count",
	)
	assert_written_sequence(
		t,
		clear_screen_home_sequence(),
		"\x1b[2J\x1b[1;1H",
		"expected erase helper write to succeed",
		"expected erase helper write to preserve the exact bytes",
	)
}

@(test)
test_attribute_and_color_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		reset_sequence(),
		"\x1b[0m",
		"expected reset_sequence to clear all attributes",
	)
	assert_sequence(
		t,
		set_attributes_sequence([]Text_Attribute{.Bold, .Underline}),
		"\x1b[1;4m",
		"expected set_attributes_sequence to join attribute codes",
	)
	assert_sequence(
		t,
		set_foreground_sequence(.Red),
		"\x1b[31m",
		"expected set_foreground_sequence to use foreground SGR code",
	)
	assert_sequence(
		t,
		set_foreground_default_sequence(),
		"\x1b[39m",
		"expected set_foreground_default_sequence to restore the default foreground",
	)
	assert_sequence(
		t,
		set_background_sequence(.Blue),
		"\x1b[44m",
		"expected set_background_sequence to use background SGR code",
	)
	assert_sequence(
		t,
		set_background_default_sequence(),
		"\x1b[49m",
		"expected set_background_default_sequence to restore the default background",
	)
	assert_sequence(
		t,
		set_background_sequence(.Bright_Cyan),
		"\x1b[106m",
		"expected bright background colors to map to 100-series SGR codes",
	)
	assert_sequence(
		t,
		set_foreground_256_sequence(123),
		"\x1b[38;5;123m",
		"expected 256-color foreground SGR",
	)
	assert_sequence(
		t,
		set_background_256_sequence(45),
		"\x1b[48;5;45m",
		"expected 256-color background SGR",
	)
	assert_sequence(
		t,
		set_foreground_rgb_sequence(1, 2, 3),
		"\x1b[38;2;1;2;3m",
		"expected RGB foreground SGR",
	)
	assert_sequence(
		t,
		set_background_rgb_sequence(4, 5, 6),
		"\x1b[48;2;4;5;6m",
		"expected RGB background SGR",
	)
}

@(test)
test_style_composition_and_write :: proc(t: ^testing.T) {
	style := Style {
		foreground     = .Green,
		background     = .Black,
		use_foreground = true,
		use_background = true,
		attributes     = []Text_Attribute{.Bold, .Underline},
	}
	assert_sequence(
		t,
		apply_style_sequence(style),
		"\x1b[0m\x1b[32m\x1b[40m\x1b[1;4m",
		"expected apply_style_sequence to compose reset, colors, and attributes",
	)
	assert_sequence(
		t,
		styled_text_sequence(style, "hi"),
		"\x1b[0m\x1b[32m\x1b[40m\x1b[1;4mhi\x1b[0m",
		"expected styled_text_sequence to wrap text with style and reset",
	)
	assert_written_sequence(
		t,
		styled_text_sequence(style, "ok"),
		"\x1b[0m\x1b[32m\x1b[40m\x1b[1;4mok\x1b[0m",
		"expected styled_text_sequence write to succeed",
		"expected styled_text_sequence output to be preserved by write",
	)
}

@(test)
test_render_sequences :: proc(t: ^testing.T) {
	region := Region {
		top_row      = 2,
		left_column  = 3,
		bottom_row   = 4,
		right_column = 6,
	}
	assert(region_width(region) == 4, "expected region_width to count inclusive columns")
	assert(region_height(region) == 3, "expected region_height to count inclusive rows")

	interior := region_interior(region)
	assert(interior.top_row == 3, "expected region_interior to move the top edge inward")
	assert(interior.left_column == 4, "expected region_interior to move the left edge inward")
	assert(interior.bottom_row == 3, "expected region_interior to move the bottom edge inward")
	assert(interior.right_column == 5, "expected region_interior to move the right edge inward")

	collapsed := region_interior(
		Region{top_row = 1, left_column = 1, bottom_row = 2, right_column = 2},
	)
	assert(collapsed.top_row == 1, "expected small frame interior to collapse to the origin row")
	assert(
		collapsed.left_column == 1,
		"expected small frame interior to collapse to the origin column",
	)
	assert(collapsed.bottom_row == 1, "expected small frame interior to collapse to one row")
	assert(collapsed.right_column == 1, "expected small frame interior to collapse to one column")

	assert_sequence(
		t,
		fill_region_sequence(region, '#'),
		"\x1b[2;3H####\x1b[3;3H####\x1b[4;3H####",
		"expected fill_region_sequence to write the fill byte across each row in the region",
	)
	assert_sequence(
		t,
		clear_region_sequence(
			Region{top_row = 0, left_column = 0, bottom_row = 1, right_column = 2},
		),
		"\x1b[1;1H  ",
		"expected clear_region_sequence to clamp the region and fill it with spaces",
	)
	assert_sequence(
		t,
		draw_frame_sequence(
			Region{top_row = 2, left_column = 4, bottom_row = 4, right_column = 8},
		),
		"\x1b[2;4H┌───┐\x1b[3;4H│   │\x1b[4;4H└───┘",
		"expected draw_frame_sequence to render a Unicode frame with a clear interior",
	)
	assert_sequence(
		t,
		draw_frame_sequence(
			Region{top_row = 3, left_column = 5, bottom_row = 3, right_column = 5},
		),
		"\x1b[3;5H┌",
		"expected draw_frame_sequence to collapse a 1x1 region to a single corner glyph",
	)
	assert_written_sequence(
		t,
		draw_frame_sequence(region),
		"\x1b[2;3H┌──┐\x1b[3;3H│  │\x1b[4;3H└──┘",
		"expected draw_frame_sequence write to succeed",
		"expected draw_frame_sequence output to be preserved by write",
	)
	_ = t
}

@(test)
test_batch_sequences :: proc(t: ^testing.T) {
	style := Style {
		foreground     = .Yellow,
		use_foreground = true,
		attributes     = []Text_Attribute{.Bold},
	}

	batch := batch_init()
	defer batch_destroy(&batch)
	batch_move_to(&batch, 2, 3)
	batch_write_text(&batch, "hi")
	batch_move_to(&batch, 2, 5)
	batch_write_styled_text(&batch, style, "!")

	assert_sequence(
		t,
		batch_sequence(&batch),
		"\x1b[2;3Hhi\x1b[0m\x1b[33m\x1b[1m!\x1b[0m",
		"expected batch_sequence to elide redundant cursor moves and append styled text",
	)

	unicode_batch := batch_init()
	defer batch_destroy(&unicode_batch)
	batch_move_to(&unicode_batch, 1, 1)
	batch_write_text(&unicode_batch, "日本")
	batch_move_to(&unicode_batch, 1, 5)
	assert_sequence(
		t,
		batch_sequence(&unicode_batch),
		"\x1b[1;1H日本",
		"expected batch cursor tracking to count wide grapheme columns",
	)

	newline_batch := batch_init()
	defer batch_destroy(&newline_batch)
	batch_move_to(&newline_batch, 1, 1)
	batch_write_text(&newline_batch, "a\nb")
	batch_move_to(&newline_batch, 1, 4)
	assert_sequence(
		t,
		batch_sequence(&newline_batch),
		"\x1b[1;1Ha\nb\x1b[1;4H",
		"expected batch_write_text to invalidate cursor tracking after a newline",
	)

	fill_batch := batch_init()
	defer batch_destroy(&fill_batch)
	batch_fill_region(
		&fill_batch,
		Region{top_row = 2, left_column = 2, bottom_row = 3, right_column = 4},
		'#',
	)
	assert_sequence(
		t,
		batch_sequence(&fill_batch),
		"\x1b[2;2H###\x1b[3;2H###",
		"expected batch_fill_region to build a bounded multi-line fill sequence",
	)

	buffer: [256]byte
	writer_builder := strings.builder_from_bytes(buffer[:])
	written, err := batch_emit_to(&fill_batch, strings.to_writer(&writer_builder))
	assert(err == nil, "expected batch_emit_to to write the buffered sequence")
	assert(
		written == len(batch_sequence(&fill_batch)),
		"expected batch_emit_to to report bytes written",
	)
	assert(
		strings.to_string(writer_builder) == batch_sequence(&fill_batch),
		"expected batch_emit_to to preserve the exact buffered sequence",
	)
	_ = t
}

@(test)
test_panel_sequences :: proc(t: ^testing.T) {
	panel := Panel {
		region = Region{top_row = 2, left_column = 2, bottom_row = 4, right_column = 10},
		title = "Status",
	}

	interior := panel_interior(panel)
	assert(interior.top_row == 3, "expected panel_interior to start below the top border")
	assert(interior.left_column == 3, "expected panel_interior to start inside the left border")
	assert(interior.bottom_row == 3, "expected panel_interior to end above the bottom border")
	assert(interior.right_column == 9, "expected panel_interior to end inside the right border")

	title_region := panel_title_region(panel)
	assert(title_region.top_row == 2, "expected panel_title_region to stay on the top border row")
	assert(
		title_region.left_column == 4,
		"expected panel_title_region to offset from the left corner",
	)
	assert(
		title_region.right_column == 9,
		"expected panel_title_region to stop before the right corner",
	)

	assert_sequence(
		t,
		draw_panel_sequence(panel),
		"\x1b[2;2H┌───────┐\x1b[3;2H│       │\x1b[4;2H└───────┘\x1b[2;4HStatus",
		"expected draw_panel_sequence to compose a frame and overlay the panel title",
	)

	filled_panel := Panel {
		region = Region{top_row = 2, left_column = 3, bottom_row = 4, right_column = 7},
		fill_interior = true,
		interior_fill = '.',
	}
	assert_sequence(
		t,
		draw_panel_sequence(filled_panel),
		"\x1b[2;3H┌───┐\x1b[3;3H│   │\x1b[4;3H└───┘\x1b[3;4H...",
		"expected draw_panel_sequence to optionally fill the panel interior after drawing the frame",
	)

	styled_panel := Panel {
		region = Region{top_row = 1, left_column = 1, bottom_row = 3, right_column = 5},
		title = "OK",
		border_style = Style{foreground = .Red, use_foreground = true},
		title_style = Style{foreground = .Cyan, use_foreground = true},
		use_border_style = true,
		use_title_style = true,
	}
	assert_sequence(
		t,
		draw_panel_sequence(styled_panel),
		"\x1b[0m\x1b[31m\x1b[1;1H┌───┐\x1b[2;1H│   │\x1b[3;1H└───┘\x1b[0m\x1b[1;3H\x1b[0m\x1b[36mOK\x1b[0m",
		"expected styled panel output to wrap border and title writes with their configured styles",
	)

	truncated_panel := Panel {
		region = Region{top_row = 1, left_column = 1, bottom_row = 3, right_column = 4},
		title = "AB\nCD",
	}
	assert_sequence(
		t,
		draw_panel_sequence(truncated_panel),
		"\x1b[1;1H┌──┐\x1b[2;1H│  │\x1b[3;1H└──┘\x1b[1;3HA",
		"expected panel titles to stay single-line and truncate to the available title width",
	)
	assert_written_sequence(
		t,
		draw_panel_sequence(panel),
		"\x1b[2;2H┌───────┐\x1b[3;2H│       │\x1b[4;2H└───────┘\x1b[2;4HStatus",
		"expected draw_panel_sequence write to succeed",
		"expected draw_panel_sequence output to be preserved by write",
	)
	_ = t
}
