package console

import "core:io"
import "core:strings"
import "core:unicode/utf8"

Batch :: struct {
	builder:       strings.Builder,
	cursor_row:    int,
	cursor_column: int,
	cursor_known:  bool,
}

batch_init :: proc(allocator := context.allocator) -> Batch {
	batch: Batch
	strings.builder_init(&batch.builder, allocator)
	return batch
}

batch_reset :: proc(batch: ^Batch) {
	strings.builder_reset(&batch.builder)
	batch.cursor_row = 0
	batch.cursor_column = 0
	batch.cursor_known = false
}

batch_destroy :: proc(batch: ^Batch) {
	strings.builder_destroy(&batch.builder)
	batch.cursor_row = 0
	batch.cursor_column = 0
	batch.cursor_known = false
}

batch_sequence :: proc(batch: ^Batch) -> string {
	return strings.to_string(batch.builder)
}

batch_emit_to :: proc(batch: ^Batch, writer: io.Writer) -> (int, io.Error) {
	return write_to(batch_sequence(batch), writer)
}

batch_emit :: proc(batch: ^Batch) -> (int, io.Error) {
	return write(batch_sequence(batch))
}

batch_write_sequence :: proc(batch: ^Batch, sequence: string) {
	strings.write_string(&batch.builder, sequence)
	batch.cursor_known = false
}

batch_move_to :: proc(batch: ^Batch, row, column: int) {
	normalized_row := positive_coordinate(row)
	normalized_column := positive_coordinate(column)
	if batch.cursor_known &&
	   batch.cursor_row == normalized_row &&
	   batch.cursor_column == normalized_column {
		return
	}

	strings.write_string(&batch.builder, cursor_goto_sequence(normalized_row, normalized_column))
	batch.cursor_row = normalized_row
	batch.cursor_column = normalized_column
	batch.cursor_known = true
}

batch_write_text :: proc(batch: ^Batch, text: string) {
	strings.write_string(&batch.builder, text)
	_batch_note_text(batch, text)
}

batch_write_styled_text :: proc(batch: ^Batch, style: Style, text: string) {
	strings.write_string(&batch.builder, styled_text_sequence(style, text))
	_batch_note_text(batch, text)
}

batch_fill_region :: proc(batch: ^Batch, region: Region, fill: byte = ' ') {
	normalized := region_normalized(region)
	width := region_width(normalized)
	for row := normalized.top_row; row <= normalized.bottom_row; row += 1 {
		batch_move_to(batch, row, normalized.left_column)
		for column := 0; column < width; column += 1 {
			strings.write_byte(&batch.builder, fill)
		}
		if batch.cursor_known {
			batch.cursor_row = row
			batch.cursor_column = normalized.left_column + width
		}
	}
}

@(private)
_batch_note_text :: proc(batch: ^Batch, text: string) {
	if !batch.cursor_known {
		return
	}

	for index := 0; index < len(text); {
		switch text[index] {
		case '\n', '\r':
			batch.cursor_known = false
			return
		case:
			graphemes, _, _, _ := utf8.decode_grapheme_clusters(
				text[index:],
				true,
				context.temp_allocator,
			)
			if len(graphemes) == 0 {
				return
			}
			batch.cursor_column += graphemes[0].width
			if len(graphemes) == 1 {
				return
			}
			index += graphemes[1].byte_index
		}
	}
}
