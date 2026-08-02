package widgets

import text_input "../text_input"
import "core:unicode/utf8"

Text_Editor_Event :: enum int {
	None = 0,
	Commit,
	Cancel,
}

Text_Editor :: struct {
	buffer:         text_input.Input_Buffer,
	utf8Pending:    [utf8.UTF_MAX]byte,
	utf8PendingLen: int,
}

text_editor_init :: proc(allocator := context.allocator) -> Text_Editor {
	return Text_Editor{buffer = text_input.input_buffer_init(allocator)}
}

text_editor_destroy :: proc(editor: ^Text_Editor) {
	text_input.input_buffer_destroy(&editor.buffer)
	editor.utf8PendingLen = 0
}

text_editor_clear :: proc(editor: ^Text_Editor) {
	text_input.input_buffer_clear(&editor.buffer)
	editor.utf8PendingLen = 0
}

text_editor_set_text :: proc(editor: ^Text_Editor, text: string) {
	text_input.input_buffer_set_text(&editor.buffer, text)
	editor.utf8PendingLen = 0
}

text_editor_string :: proc(editor: ^Text_Editor) -> string {
	return text_input.input_buffer_string(&editor.buffer)
}

text_editor_handle_byte :: proc(editor: ^Text_Editor, input: byte) -> (bool, Text_Editor_Event) {
	switch input {
	case 1:
		editor.utf8PendingLen = 0
		text_input.input_buffer_move_cursor_start(&editor.buffer)
		return true, .None
	case 5:
		editor.utf8PendingLen = 0
		text_input.input_buffer_move_cursor_end(&editor.buffer)
		return true, .None
	case 8, 127:
		editor.utf8PendingLen = 0
		return text_input.input_buffer_backspace(&editor.buffer), .None
	case '\r':
		editor.utf8PendingLen = 0
		return true, .Commit
	case 0x1b:
		editor.utf8PendingLen = 0
		return true, .Cancel
	case:
		if input >= 32 || input == '\t' {
			return text_editor_handle_text_byte(editor, input), .None
		}
	}
	return false, .None
}

text_editor_handle_text_byte :: proc(editor: ^Text_Editor, input: byte) -> bool {
	if input < utf8.RUNE_SELF {
		editor.utf8PendingLen = 0
		text_input.input_buffer_push_byte(&editor.buffer, input)
		return true
	}

	if editor.utf8PendingLen == 0 {
		if text_editor_utf8_sequence_length(input) == 0 {
			return false
		}
		editor.utf8Pending[0] = input
		editor.utf8PendingLen = 1
	} else {
		if input < utf8.LOCB ||
		   input > utf8.HICB ||
		   editor.utf8PendingLen >= len(editor.utf8Pending) {
			editor.utf8PendingLen = 0
			return false
		}
		editor.utf8Pending[editor.utf8PendingLen] = input
		editor.utf8PendingLen += 1
	}

	expectedLength := text_editor_utf8_sequence_length(editor.utf8Pending[0])
	if editor.utf8PendingLen < expectedLength {
		return false
	}
	_, width := utf8.decode_rune(editor.utf8Pending[:expectedLength])
	if width != expectedLength {
		editor.utf8PendingLen = 0
		return false
	}
	text_input.input_buffer_push_text(&editor.buffer, string(editor.utf8Pending[:expectedLength]))
	editor.utf8PendingLen = 0
	return true
}

text_editor_utf8_sequence_length :: proc(input: byte) -> int {
	switch {
	case input < utf8.RUNE_SELF:
		return 1
	case input >= 0xc2 && input <= 0xdf:
		return 2
	case input >= 0xe0 && input <= 0xef:
		return 3
	case input >= 0xf0 && input <= 0xf4:
		return 4
	}
	return 0
}
