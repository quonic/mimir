package input

import "../../console"
import "core:testing"

@(private)
_push_string :: proc(state: ^Input_State, s: string) -> (event: Input_Event, ok: bool) {
	for i := 0; i < len(s); i += 1 {
		event, ok = input_push_byte(state, s[i])
	}
	return
}

@(test)
test_legacy_plain_char :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := input_push_byte(&state, 'a')
	assert(ok, "expected plain char to resolve immediately")
	key, is_key := event.(Key_Event)
	assert(is_key, "expected a Key_Event")
	assert(key.code == .Char, "expected .Char code")
	assert(key.char == 'a', "expected char 'a'")
	assert(key.modifiers == {}, "expected no modifiers")
}

@(test)
test_legacy_ctrl_c :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := input_push_byte(&state, 3)
	assert(ok, "expected ctrl+c to resolve immediately")
	key, is_key := event.(Key_Event)
	assert(is_key, "expected a Key_Event")
	assert(key.code == .Char && key.char == 'c', "expected char 'c'")
	assert(key.modifiers == {.Ctrl}, "expected ctrl modifier")
}

@(test)
test_legacy_arrow_keys :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1b[A")
	assert(ok, "expected arrow-up sequence to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Arrow_Up, "expected Arrow_Up")
	assert(key.modifiers == {}, "expected no modifiers on plain arrow key")
}

@(test)
test_legacy_modified_arrow_key :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1b[1;6C")
	assert(ok, "expected modified arrow-right sequence to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Arrow_Right, "expected Arrow_Right")
	assert(key.modifiers == {.Shift, .Ctrl}, "expected shift+ctrl modifiers")
}

@(test)
test_legacy_function_key :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1b[3~")
	assert(ok, "expected delete sequence to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Delete, "expected Delete")
}

@(test)
test_alt_prefixed_char :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1bc")
	assert(ok, "expected alt+c to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Char && key.char == 'c', "expected char 'c'")
	assert(key.modifiers == {.Alt}, "expected alt modifier")
}

@(test)
test_csi_u_ctrl_letter :: proc(t: ^testing.T) {
	state: Input_State
	// CSI-u encoding for ctrl+shift+i, per fixterms example.
	event, ok := _push_string(&state, "\x1b[73;5u")
	assert(ok, "expected CSI-u sequence to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Char && key.char == 'I', "expected char 'I'")
	assert(key.modifiers == {.Ctrl}, "expected ctrl modifier")
}

@(test)
test_kitty_event_types :: proc(t: ^testing.T) {
	state: Input_State
	press, press_ok := _push_string(&state, "\x1b[97;1:1u")
	assert(press_ok, "expected kitty press event to resolve")
	press_key, press_is_key := press.(Key_Event)
	assert(press_is_key && press_key.event_type == .Press, "expected press event type")

	repeat, repeat_ok := _push_string(&state, "\x1b[97;1:2u")
	assert(repeat_ok, "expected kitty repeat event to resolve")
	repeat_key, repeat_is_key := repeat.(Key_Event)
	assert(repeat_is_key && repeat_key.event_type == .Repeat, "expected repeat event type")

	release, release_ok := _push_string(&state, "\x1b[97;1:3u")
	assert(release_ok, "expected kitty release event to resolve")
	release_key, release_is_key := release.(Key_Event)
	assert(release_is_key && release_key.event_type == .Release, "expected release event type")
}

@(test)
test_kitty_functional_key :: proc(t: ^testing.T) {
	state: Input_State
	// CAPS_LOCK per Kitty's functional key table.
	event, ok := _push_string(&state, "\x1b[57358u")
	assert(ok, "expected kitty functional key sequence to resolve")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Caps_Lock, "expected Caps_Lock")
}

@(test)
test_sgr_mouse_passthrough :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1b[<0;12;7M")
	assert(ok, "expected mouse sequence to resolve")
	mouse, is_mouse := event.(console.Mouse_Event)
	assert(is_mouse, "expected a console.Mouse_Event")
	assert(mouse.kind == .Press && mouse.button == .Left, "expected left press")
	assert(mouse.column == 12 && mouse.row == 7, "expected parsed coordinates")
}

@(test)
test_bracketed_paste :: proc(t: ^testing.T) {
	state: Input_State
	full := "\x1b[200~hello world\x1b[201~"
	event: Input_Event
	ok: bool
	for i := 0; i < len(full); i += 1 {
		event, ok = input_push_byte(&state, full[i])
		if i < len(full) - 1 {
			assert(!ok, "expected paste to remain pending until terminator")
		}
	}
	assert(ok, "expected paste to resolve at terminator")
	paste, is_paste := event.(Paste_Event)
	assert(is_paste, "expected a Paste_Event")
	assert(paste.text == "hello world", "expected exact pasted text")
	delete(paste.text)
	delete(state.paste_buf)
}

@(test)
test_unknown_sequence :: proc(t: ^testing.T) {
	state: Input_State
	event, ok := _push_string(&state, "\x1b[9999999999z")
	assert(ok, "expected malformed sequence to resolve as unknown")
	unknown, is_unknown := event.(Unknown_Event)
	assert(is_unknown, "expected an Unknown_Event")
	delete(unknown.raw)
}

@(test)
test_flush_lone_escape :: proc(t: ^testing.T) {
	state: Input_State
	_, ok := input_push_byte(&state, 0x1b)
	assert(!ok, "expected lone escape byte to remain pending")
	event, flush_ok := input_flush(&state)
	assert(flush_ok, "expected flush to resolve the pending escape")
	key, is_key := event.(Key_Event)
	assert(is_key && key.code == .Escape, "expected a lone Escape key event")
	assert(key.modifiers == {}, "expected no modifiers on a flushed lone escape")
}

@(test)
test_kitty_negotiation_success :: proc(t: ^testing.T) {
	state: Input_State
	_ = input_begin_protocol_detection(&state)
	// Terminal answers the flags query first, then the DA1 sentinel.
	_, ok1 := _push_string(&state, "\x1b[?3u")
	assert(!ok1, "expected negotiation replies to produce no user-visible event")
	_, ok2 := _push_string(&state, "\x1b[?6c")
	assert(!ok2, "expected negotiation replies to produce no user-visible event")
	assert(state.protocol == .Kitty, "expected protocol to settle on Kitty")
}

@(test)
test_kitty_negotiation_unsupported :: proc(t: ^testing.T) {
	state: Input_State
	_ = input_begin_protocol_detection(&state)
	// Terminal never answers the flags query; only the DA1 sentinel arrives.
	_, ok := _push_string(&state, "\x1b[?6c")
	assert(!ok, "expected negotiation replies to produce no user-visible event")
	assert(state.protocol == .CSI_U, "expected protocol to fall back to CSI_U")
}
