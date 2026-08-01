# text_input

`text_input` provides a grapheme-aware editable text buffer for terminal and other
text input interfaces. It has no dependency on application state, configuration, or
console rendering.

Create a buffer with `input_buffer_init`, release it with `input_buffer_destroy`, and
use the `input_buffer_*` procedures for cursor movement, selection, editing, and
submission. Cursor and selection positions are grapheme indices, so operations keep
multi-byte and combining-character graphemes intact.

The `unicode_*` procedures expose grapheme indexing and terminal display-width
helpers for consumers that render or truncate the buffer's text. Callers may supply
an allocator to initialization and submission; otherwise the current context
allocator is used.
