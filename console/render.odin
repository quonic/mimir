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
	line_end:     string,
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

// Frame_Edges selects which edges of a frame are drawn.
// The zero value means all edges are visible. Any non-zero value draws only
// the edges named in its low bits, so Frame_Edges_Explicit alone (no edge
// bits) draws no edges at all.
Frame_Edges :: u8

Frame_Edge_Top :: Frame_Edges(0b00001)
Frame_Edge_Left :: Frame_Edges(0b00010)
Frame_Edge_Bottom :: Frame_Edges(0b00100)
Frame_Edge_Right :: Frame_Edges(0b01000)
Frame_Edges_All :: Frame_Edges(0b01111)
Frame_Edges_Explicit :: Frame_Edges(0b10000)

frame_edge_visible :: proc(edges: Frame_Edges, edge: Frame_Edges) -> bool {
	if edges == 0 {
		return true
	}
	return (edges & edge) != 0
}

// frame_line_end returns the terminator glyph for a line segment that ends
// without a corner, falling back to the plain line glyph.
frame_line_end :: proc(glyphs: Frame_Glyphs, line: string) -> string {
	if len(glyphs.line_end) > 0 {
		return glyphs.line_end
	}
	return line
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

// region_interior_edges returns the region inside the given region, shrinking
// only the edges that are visible. Edges that are not drawn do not consume
// space, so content can fill their cells.
region_interior_edges :: proc(region: Region, edges: Frame_Edges) -> Region {
	normalized := region_normalized(region)
	top := normalized.top_row
	left := normalized.left_column
	bottom := normalized.bottom_row
	right := normalized.right_column

	if frame_edge_visible(edges, Frame_Edge_Top) {
		top += 1
	}
	if frame_edge_visible(edges, Frame_Edge_Left) {
		left += 1
	}
	if frame_edge_visible(edges, Frame_Edge_Bottom) {
		bottom -= 1
	}
	if frame_edge_visible(edges, Frame_Edge_Right) {
		right -= 1
	}

	if bottom < top || right < left {
		return Region {
			top_row = normalized.top_row,
			left_column = normalized.left_column,
			bottom_row = normalized.top_row,
			right_column = normalized.left_column,
		}
	}

	return Region{top_row = top, left_column = left, bottom_row = bottom, right_column = right}
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

// draw_frame_sequence renders the visible edges of a frame. A corner glyph is
// drawn only when both of its adjacent edges are visible; a line segment that
// ends without a corner is terminated with the line_end glyph (or the plain
// line glyph when line_end is empty).
draw_frame_sequence :: proc(region: Region, glyphs: Frame_Glyphs, edges: Frame_Edges) -> string {
	normalized := region_normalized(region)
	width := region_width(normalized)
	height := region_height(normalized)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)

	top_visible := frame_edge_visible(edges, Frame_Edge_Top)
	left_visible := frame_edge_visible(edges, Frame_Edge_Left)
	bottom_visible := frame_edge_visible(edges, Frame_Edge_Bottom)
	right_visible := frame_edge_visible(edges, Frame_Edge_Right)

	if width == 1 {
		// The single column is the left edge; the right edge is ignored.
		if left_visible {
			for row := normalized.top_row; row <= normalized.bottom_row; row += 1 {
				strings.write_string(&builder, cursor_goto_sequence(row, normalized.left_column))
				if row == normalized.top_row {
					if top_visible {
						strings.write_string(&builder, glyphs.top_left)
					} else {
						strings.write_string(&builder, glyphs.vertical)
					}
				} else if row == normalized.bottom_row {
					if bottom_visible {
						strings.write_string(&builder, glyphs.bottom_left)
					} else {
						strings.write_string(&builder, glyphs.vertical)
					}
				} else {
					strings.write_string(&builder, glyphs.vertical)
				}
			}
		}
		return strings.to_string(builder)
	}

	if height == 1 {
		// The single row is the top edge; the bottom edge is ignored.
		if top_visible {
			strings.write_string(
				&builder,
				cursor_goto_sequence(normalized.top_row, normalized.left_column),
			)
			if left_visible {
				strings.write_string(&builder, glyphs.top_left)
			} else {
				strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
			}
			for column := 0; column < width - 2; column += 1 {
				strings.write_string(&builder, glyphs.horizontal)
			}
			if right_visible {
				strings.write_string(&builder, glyphs.top_right)
			} else {
				strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
			}
		}
		return strings.to_string(builder)
	}

	if top_visible {
		strings.write_string(
			&builder,
			cursor_goto_sequence(normalized.top_row, normalized.left_column),
		)
		if left_visible {
			strings.write_string(&builder, glyphs.top_left)
		} else {
			strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
		}
		for column := 0; column < width - 2; column += 1 {
			strings.write_string(&builder, glyphs.horizontal)
		}
		if right_visible {
			strings.write_string(&builder, glyphs.top_right)
		} else {
			strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
		}
	}

	for row := normalized.top_row + 1; row < normalized.bottom_row; row += 1 {
		strings.write_string(&builder, cursor_goto_sequence(row, normalized.left_column))
		if left_visible {
			strings.write_string(&builder, glyphs.vertical)
		}
		for column := 0; column < width - 2; column += 1 {
			strings.write_string(&builder, glyphs.fill)
		}
		if right_visible {
			strings.write_string(&builder, glyphs.vertical)
		}
	}

	if bottom_visible {
		strings.write_string(
			&builder,
			cursor_goto_sequence(normalized.bottom_row, normalized.left_column),
		)
		if left_visible {
			strings.write_string(&builder, glyphs.bottom_left)
		} else {
			strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
		}
		for column := 0; column < width - 2; column += 1 {
			strings.write_string(&builder, glyphs.horizontal)
		}
		if right_visible {
			strings.write_string(&builder, glyphs.bottom_right)
		} else {
			strings.write_string(&builder, frame_line_end(glyphs, glyphs.horizontal))
		}
	}

	return strings.to_string(builder)
}

draw_frame_with_glyphs :: proc(
	region: Region,
	glyphs: Frame_Glyphs = ASCII_Frame_Glyphs,
	edges: Frame_Edges = 0,
) -> (
	int,
	io.Error,
) {
	return write(draw_frame_sequence(region, glyphs, edges))
}

draw_frame :: proc(
	region: Region,
	glyphs: Frame_Glyphs = ASCII_Frame_Glyphs,
	edges: Frame_Edges = 0,
) -> (
	int,
	io.Error,
) {
	return write(draw_frame_sequence(region, glyphs, edges))
}
