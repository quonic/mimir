package console

import "core:io"
import "core:strings"

Region :: struct {
	top_row:      int,
	left_column:  int,
	bottom_row:   int,
	right_column: int,
}

Frame_Glyphs :: struct {
	top_left:     string,
	top_right:    string,
	bottom_left:  string,
	bottom_right: string,
	horizontal:   string,
	vertical:     string,
	fill:         string,
}

ASCII_Frame_Glyphs :: Frame_Glyphs {
	top_left     = "┌",
	top_right    = "┐",
	bottom_left  = "└",
	bottom_right = "┘",
	horizontal   = "─",
	vertical     = "│",
	fill         = " ",
}

region_normalized :: proc(region: Region) -> Region {
	top := positive_coordinate(region.top_row)
	left := positive_coordinate(region.left_column)
	bottom := positive_coordinate(region.bottom_row)
	right := positive_coordinate(region.right_column)

	if bottom < top {
		bottom = top
	}
	if right < left {
		right = left
	}

	return Region{top_row = top, left_column = left, bottom_row = bottom, right_column = right}
}

region_width :: proc(region: Region) -> int {
	normalized := region_normalized(region)
	return normalized.right_column - normalized.left_column + 1
}

region_height :: proc(region: Region) -> int {
	normalized := region_normalized(region)
	return normalized.bottom_row - normalized.top_row + 1
}

region_interior :: proc(region: Region) -> Region {
	normalized := region_normalized(region)
	if region_width(normalized) <= 2 || region_height(normalized) <= 2 {
		return Region {
			top_row = normalized.top_row,
			left_column = normalized.left_column,
			bottom_row = normalized.top_row,
			right_column = normalized.left_column,
		}
	}

	return Region {
		top_row = normalized.top_row + 1,
		left_column = normalized.left_column + 1,
		bottom_row = normalized.bottom_row - 1,
		right_column = normalized.right_column - 1,
	}
}

fill_region_sequence :: proc(region: Region, fill: byte = ' ') -> string {
	normalized := region_normalized(region)
	width := region_width(normalized)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)

	for row := normalized.top_row; row <= normalized.bottom_row; row += 1 {
		strings.write_string(&builder, cursor_goto_sequence(row, normalized.left_column))
		for column := 0; column < width; column += 1 {
			strings.write_byte(&builder, fill)
		}
	}

	return strings.to_string(builder)
}

fill_region :: proc(region: Region, fill: byte = ' ') -> (int, io.Error) {
	return write(fill_region_sequence(region, fill))
}

clear_region_sequence :: proc(region: Region) -> string {
	return fill_region_sequence(region, ' ')
}

clear_region :: proc(region: Region) -> (int, io.Error) {
	return write(clear_region_sequence(region))
}

draw_frame_sequence_with_glyphs :: proc(region: Region, glyphs: Frame_Glyphs) -> string {
	normalized := region_normalized(region)
	width := region_width(normalized)
	height := region_height(normalized)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)

	if width == 1 && height == 1 {
		strings.write_string(
			&builder,
			cursor_goto_sequence(normalized.top_row, normalized.left_column),
		)
		strings.write_string(&builder, glyphs.top_left)
		return strings.to_string(builder)
	}

	strings.write_string(
		&builder,
		cursor_goto_sequence(normalized.top_row, normalized.left_column),
	)
	strings.write_string(&builder, glyphs.top_left)
	for column := 0; column < width - 2; column += 1 {
		strings.write_string(&builder, glyphs.horizontal)
	}
	if width > 1 {
		strings.write_string(&builder, glyphs.top_right)
	}

	for row := normalized.top_row + 1; row < normalized.bottom_row; row += 1 {
		strings.write_string(&builder, cursor_goto_sequence(row, normalized.left_column))
		strings.write_string(&builder, glyphs.vertical)
		if width > 2 {
			for column := 0; column < width - 2; column += 1 {
				strings.write_string(&builder, glyphs.fill)
			}
		}
		if width > 1 {
			strings.write_string(&builder, glyphs.vertical)
		}
	}

	if height > 1 {
		strings.write_string(
			&builder,
			cursor_goto_sequence(normalized.bottom_row, normalized.left_column),
		)
		strings.write_string(&builder, glyphs.bottom_left)
		for column := 0; column < width - 2; column += 1 {
			strings.write_string(&builder, glyphs.horizontal)
		}
		if width > 1 {
			strings.write_string(&builder, glyphs.bottom_right)
		}
	}

	return strings.to_string(builder)
}

draw_frame_sequence :: proc(region: Region) -> string {
	return draw_frame_sequence_with_glyphs(region, ASCII_Frame_Glyphs)
}

draw_frame_with_glyphs :: proc(region: Region, glyphs: Frame_Glyphs) -> (int, io.Error) {
	return write(draw_frame_sequence_with_glyphs(region, glyphs))
}

draw_frame :: proc(region: Region) -> (int, io.Error) {
	return write(draw_frame_sequence(region))
}
