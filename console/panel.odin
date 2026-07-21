package console

import "core:io"

Panel :: struct {
	region:           Region,
	title:            string,
	border_style:     Style,
	title_style:      Style,
	use_border_style: bool,
	use_title_style:  bool,
	fill_interior:    bool,
	interior_fill:    byte,
}

panel_interior :: proc(panel: Panel) -> Region {
	return region_interior(panel.region)
}

panel_title_region :: proc(panel: Panel) -> Region {
	normalized := region_normalized(panel.region)
	start := normalized.left_column + 2
	finish := normalized.right_column - 1
	if finish < start {
		return Region {
			top_row = normalized.top_row,
			left_column = normalized.left_column,
			bottom_row = normalized.top_row,
			right_column = normalized.left_column,
		}
	}

	return Region {
		top_row = normalized.top_row,
		left_column = start,
		bottom_row = normalized.top_row,
		right_column = finish,
	}
}

draw_panel_sequence :: proc(panel: Panel) -> string {
	batch := batch_init(context.temp_allocator)
	defer batch_destroy(&batch)
	batch_draw_panel(&batch, panel)
	return batch_sequence(&batch)
}

draw_panel :: proc(panel: Panel) -> (int, io.Error) {
	return write(draw_panel_sequence(panel))
}

batch_draw_panel :: proc(batch: ^Batch, panel: Panel) {
	normalized := region_normalized(panel.region)
	frame_sequence := draw_frame_sequence(normalized)
	if panel.use_border_style {
		batch_write_sequence(batch, styled_text_sequence(panel.border_style, frame_sequence))
	} else {
		batch_write_sequence(batch, frame_sequence)
	}

	if panel.fill_interior {
		fill := panel.interior_fill
		if fill == 0 {
			fill = ' '
		}
		batch_fill_region(batch, panel_interior(panel), fill)
	}

	title := _panel_title_text(panel)
	if len(title) == 0 {
		return
	}

	title_region := panel_title_region(panel)
	batch_move_to(batch, title_region.top_row, title_region.left_column)
	if panel.use_title_style {
		batch_write_styled_text(batch, panel.title_style, title)
	} else {
		batch_write_text(batch, title)
	}
}

@(private)
_panel_title_text :: proc(panel: Panel) -> string {
	title := panel.title
	for index := 0; index < len(title); index += 1 {
		if title[index] == '\n' || title[index] == '\r' {
			title = title[:index]
			break
		}
	}

	max_width := region_width(panel_title_region(panel))
	if max_width < 1 {
		return ""
	}
	if len(title) > max_width {
		return title[:max_width]
	}
	return title
}
