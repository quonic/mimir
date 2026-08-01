package widgets

import "core:testing"

@(test)
test_text_editor_handles_utf8_and_commit :: proc(t: ^testing.T) {
	editor := text_editor_init(context.temp_allocator)
	defer text_editor_destroy(&editor)

	handled, event := text_editor_handle_byte(&editor, 0xc3)
	assert(!handled && event == .None, "expected partial UTF-8 sequence to wait")
	handled, event = text_editor_handle_byte(&editor, 0xa9)
	assert(handled && event == .None, "expected completed UTF-8 sequence to insert")
	assert(text_editor_string(&editor) == "\xc3\xa9", "expected UTF-8 text to be preserved")
	handled, event = text_editor_handle_byte(&editor, '\r')
	assert(handled && event == .Commit, "expected Enter to commit")
	_ = t
}

@(test)
test_text_editor_cancels_without_clearing_value :: proc(t: ^testing.T) {
	editor := text_editor_init(context.temp_allocator)
	defer text_editor_destroy(&editor)
	text_editor_set_text(&editor, "value")

	handled, event := text_editor_handle_byte(&editor, 0x1b)
	assert(handled && event == .Cancel, "expected Escape to cancel")
	assert(
		text_editor_string(&editor) == "value",
		"expected cancel to leave clearing to the owner",
	)
	_ = t
}
