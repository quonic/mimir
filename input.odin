package main

import "core:strings"

Input_Buffer :: struct {
	text:                [dynamic]byte,
	cursorGraphemeIndex: int,
	selectionAnchor:     int,
}

input_buffer_init :: proc(allocator := context.allocator) -> Input_Buffer {
	buffer: Input_Buffer
	buffer.text = make([dynamic]byte, 0, 0, allocator)
	buffer.selectionAnchor = -1
	return buffer
}

input_buffer_destroy :: proc(buffer: ^Input_Buffer) {
	delete(buffer.text)
	buffer.text = nil
}

input_buffer_string :: proc(buffer: ^Input_Buffer) -> string {
	return string(buffer.text[:])
}

input_buffer_cursor_position :: proc(buffer: ^Input_Buffer) -> int {
	input_buffer_clamp_cursor(buffer)
	return buffer.cursorGraphemeIndex
}

input_buffer_has_selection :: proc(buffer: ^Input_Buffer) -> bool {
	input_buffer_clamp_cursor(buffer)
	return buffer.selectionAnchor >= 0 && buffer.selectionAnchor != buffer.cursorGraphemeIndex
}

input_buffer_selection_start :: proc(buffer: ^Input_Buffer) -> int {
	input_buffer_clamp_cursor(buffer)
	if !input_buffer_has_selection(buffer) || buffer.selectionAnchor > buffer.cursorGraphemeIndex {
		return buffer.cursorGraphemeIndex
	}
	return buffer.selectionAnchor
}

input_buffer_selection_end :: proc(buffer: ^Input_Buffer) -> int {
	input_buffer_clamp_cursor(buffer)
	if !input_buffer_has_selection(buffer) || buffer.selectionAnchor < buffer.cursorGraphemeIndex {
		return buffer.cursorGraphemeIndex
	}
	return buffer.selectionAnchor
}

input_buffer_selection_text :: proc(buffer: ^Input_Buffer) -> string {
	if !input_buffer_has_selection(buffer) {
		return ""
	}
	text := input_buffer_string(buffer)
	start := unicode_grapheme_to_byte_offset(text, input_buffer_selection_start(buffer))
	finish := unicode_grapheme_to_byte_offset(text, input_buffer_selection_end(buffer))
	return text[start:finish]
}

input_buffer_clear_selection :: proc(buffer: ^Input_Buffer) {
	buffer.selectionAnchor = -1
}

input_buffer_select_all :: proc(buffer: ^Input_Buffer) {
	buffer.selectionAnchor = 0
	buffer.cursorGraphemeIndex = unicode_grapheme_count(input_buffer_string(buffer))
}

input_buffer_select_range :: proc(buffer: ^Input_Buffer, anchor, cursor: int) {
	text := input_buffer_string(buffer)
	buffer.selectionAnchor = unicode_clamp_grapheme_index(text, anchor)
	buffer.cursorGraphemeIndex = unicode_clamp_grapheme_index(text, cursor)
}

input_buffer_extend_selection_to :: proc(buffer: ^Input_Buffer, graphemeIndex: int) {
	input_buffer_clamp_cursor(buffer)
	if buffer.selectionAnchor < 0 {
		buffer.selectionAnchor = buffer.cursorGraphemeIndex
	}
	buffer.cursorGraphemeIndex = unicode_clamp_grapheme_index(
		input_buffer_string(buffer),
		graphemeIndex,
	)
}

input_buffer_delete_selection :: proc(buffer: ^Input_Buffer) -> bool {
	if !input_buffer_has_selection(buffer) {
		return false
	}

	text := input_buffer_string(buffer)
	start := unicode_grapheme_to_byte_offset(text, input_buffer_selection_start(buffer))
	finish := unicode_grapheme_to_byte_offset(text, input_buffer_selection_end(buffer))
	removed := finish - start
	for index := start; index < len(buffer.text) - removed; index += 1 {
		buffer.text[index] = buffer.text[index + removed]
	}
	for index := 0; index < removed; index += 1 {
		pop(&buffer.text)
	}
	buffer.cursorGraphemeIndex = unicode_grapheme_count(text[:start])
	input_buffer_clear_selection(buffer)
	return true
}

input_buffer_push_byte :: proc(buffer: ^Input_Buffer, value: byte) {
	input_buffer_clamp_cursor(buffer)
	input_buffer_delete_selection(buffer)
	text := input_buffer_string(buffer)
	bytePosition := unicode_grapheme_to_byte_offset(text, buffer.cursorGraphemeIndex)
	append(&buffer.text, value)
	for index := len(buffer.text) - 1; index > bytePosition; index -= 1 {
		buffer.text[index] = buffer.text[index - 1]
	}
	buffer.text[bytePosition] = value
	buffer.cursorGraphemeIndex = unicode_clamp_grapheme_index(
		input_buffer_string(buffer),
		buffer.cursorGraphemeIndex + 1,
	)
}

input_buffer_push_text :: proc(buffer: ^Input_Buffer, text: string) {
	if len(text) == 0 {
		return
	}

	input_buffer_clamp_cursor(buffer)
	input_buffer_delete_selection(buffer)
	current := input_buffer_string(buffer)
	bytePosition := unicode_grapheme_to_byte_offset(current, buffer.cursorGraphemeIndex)
	oldLength := len(buffer.text)
	for index := 0; index < len(text); index += 1 {
		append(&buffer.text, 0)
	}
	for index := oldLength - 1; index >= bytePosition; index -= 1 {
		buffer.text[index + len(text)] = buffer.text[index]
		if index == 0 {
			break
		}
	}
	copy(buffer.text[bytePosition:bytePosition + len(text)], transmute([]byte)text)
	buffer.cursorGraphemeIndex += unicode_grapheme_count(text)
}

input_buffer_backspace :: proc(buffer: ^Input_Buffer) -> bool {
	input_buffer_clamp_cursor(buffer)
	if input_buffer_delete_selection(buffer) {
		return true
	}
	if len(buffer.text) == 0 || buffer.cursorGraphemeIndex == 0 {
		return false
	}
	text := input_buffer_string(buffer)
	start := unicode_grapheme_to_byte_offset(text, buffer.cursorGraphemeIndex - 1)
	finish := unicode_grapheme_to_byte_offset(text, buffer.cursorGraphemeIndex)
	removed := finish - start
	for index := start; index < len(buffer.text) - removed; index += 1 {
		buffer.text[index] = buffer.text[index + removed]
	}
	for index := 0; index < removed; index += 1 {
		pop(&buffer.text)
	}
	buffer.cursorGraphemeIndex -= 1
	return true
}

input_buffer_clear :: proc(buffer: ^Input_Buffer) {
	clear(&buffer.text)
	buffer.cursorGraphemeIndex = 0
	input_buffer_clear_selection(buffer)
}

input_buffer_set_text :: proc(buffer: ^Input_Buffer, text: string) {
	input_buffer_clear(buffer)
	input_buffer_push_text(buffer, text)
}

input_buffer_move_cursor_left :: proc(buffer: ^Input_Buffer) -> bool {
	input_buffer_clamp_cursor(buffer)
	if input_buffer_has_selection(buffer) {
		buffer.cursorGraphemeIndex = input_buffer_selection_start(buffer)
		input_buffer_clear_selection(buffer)
		return true
	}
	if buffer.cursorGraphemeIndex == 0 {
		return false
	}
	buffer.cursorGraphemeIndex -= 1
	return true
}

input_buffer_move_cursor_right :: proc(buffer: ^Input_Buffer) -> bool {
	input_buffer_clamp_cursor(buffer)
	if input_buffer_has_selection(buffer) {
		buffer.cursorGraphemeIndex = input_buffer_selection_end(buffer)
		input_buffer_clear_selection(buffer)
		return true
	}
	if buffer.cursorGraphemeIndex >= unicode_grapheme_count(input_buffer_string(buffer)) {
		return false
	}
	buffer.cursorGraphemeIndex += 1
	return true
}

input_buffer_move_cursor_start :: proc(buffer: ^Input_Buffer) {
	if input_buffer_has_selection(buffer) {
		buffer.cursorGraphemeIndex = input_buffer_selection_start(buffer)
	} else {
		buffer.cursorGraphemeIndex = 0
	}
	input_buffer_clear_selection(buffer)
}

input_buffer_move_cursor_end :: proc(buffer: ^Input_Buffer) {
	if input_buffer_has_selection(buffer) {
		buffer.cursorGraphemeIndex = input_buffer_selection_end(buffer)
	} else {
		buffer.cursorGraphemeIndex = unicode_grapheme_count(input_buffer_string(buffer))
	}
	input_buffer_clear_selection(buffer)
}

input_buffer_delete_at_cursor :: proc(buffer: ^Input_Buffer) -> bool {
	input_buffer_clamp_cursor(buffer)
	if input_buffer_delete_selection(buffer) {
		return true
	}
	text := input_buffer_string(buffer)
	if buffer.cursorGraphemeIndex >= unicode_grapheme_count(text) {
		return false
	}
	start := unicode_grapheme_to_byte_offset(text, buffer.cursorGraphemeIndex)
	finish := unicode_grapheme_to_byte_offset(text, buffer.cursorGraphemeIndex + 1)
	removed := finish - start
	for index := start; index < len(buffer.text) - removed; index += 1 {
		buffer.text[index] = buffer.text[index + removed]
	}
	for index := 0; index < removed; index += 1 {
		pop(&buffer.text)
	}
	return true
}

input_buffer_line_count :: proc(buffer: ^Input_Buffer) -> int {
	if len(buffer.text) == 0 {
		return 1
	}

	lines := 1
	for ch in buffer.text {
		if ch == '\n' {
			lines += 1
		}
	}
	return lines
}

input_buffer_submit :: proc(buffer: ^Input_Buffer, allocator := context.allocator) -> string {
	text := strings.clone(input_buffer_string(buffer), allocator)
	input_buffer_clear(buffer)
	return text
}

input_buffer_clamp_cursor :: proc(buffer: ^Input_Buffer) {
	buffer.cursorGraphemeIndex = unicode_clamp_grapheme_index(
		input_buffer_string(buffer),
		buffer.cursorGraphemeIndex,
	)
	if buffer.selectionAnchor >= 0 {
		buffer.selectionAnchor = unicode_clamp_grapheme_index(
			input_buffer_string(buffer),
			buffer.selectionAnchor,
		)
	}
}
