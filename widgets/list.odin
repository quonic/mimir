package widgets

import console "../console"
import text_input "../text_input"
import "core:strings"

List_Render_Options :: struct {
	cursorIndex:        int,
	selectedIndex:      int,
	focused:            bool,
	showSelectedMarker: bool,
}

list_cursor_after_move :: proc(cursorIndex, itemCount, delta: int) -> int {
	if itemCount <= 0 {
		return 0
	}

	cursor := cursorIndex + delta
	for cursor < 0 {
		cursor += itemCount
	}
	for cursor >= itemCount {
		cursor -= itemCount
	}
	return cursor
}

list_render :: proc(
	batch: ^console.Batch,
	region: console.Region,
	labels: []string,
	options: List_Render_Options,
) {
	width := console.region_width(region)
	if width <= 0 || region.top_row > region.bottom_row {
		return
	}

	for label, index in labels {
		row := region.top_row + index
		if row > region.bottom_row {
			break
		}

		prefix := "  "
		if options.focused && index == options.cursorIndex {
			prefix = "> "
		} else if options.showSelectedMarker && index == options.selectedIndex {
			prefix = "* "
		}
		line := strings.concatenate({prefix, label}, context.temp_allocator)
		list_write_clipped_line(batch, row, region.left_column, width, line)
	}
}

list_write_clipped_line :: proc(batch: ^console.Batch, row, column, width: int, text: string) {
	if width <= 0 {
		return
	}

	finish := 0
	remaining := width
	for finish < len(text) && remaining > 0 {
		next := text_input.unicode_next_grapheme_offset(text, finish)
		if next <= finish {
			break
		}
		graphemeWidth := text_input.unicode_text_width(text[finish:next])
		if graphemeWidth > remaining {
			break
		}
		remaining -= graphemeWidth
		finish = next
	}
	console.batch_move_to(batch, row, column)
	console.batch_write_text(batch, text[:finish])
}
