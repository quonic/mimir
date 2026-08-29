package input

import "../../console"
import "core:fmt"
import "core:unicode/utf8"

// Csi_Field is one `;`-separated parameter, with an optional `:`-separated
// sub-value (used for the Kitty event-type sub-field on the modifier field).
@(private)
Csi_Field :: struct {
	value:   int,
	sub:     int,
	has_sub: bool,
}

// input_begin_protocol_detection returns the bytes to write to the terminal
// to start Kitty-protocol negotiation: a query for the current progressive
// enhancement flags (which only a Kitty-protocol terminal answers) followed
// by a primary Device Attributes request used purely as a sentinel. Feed the
// terminal's reply back into `input_push_byte` like any other input; the
// replies are consumed internally and never surfaced as an `Input_Event`.
input_begin_protocol_detection :: proc(state: ^Input_State) -> string {
	state.awaiting_negotiation = true
	return fmt.tprintf("\x1b[?u\x1b[=3;1u%s", console.device_attributes_query_sequence())
}

// input_push_byte feeds one raw terminal byte into the parser. It returns an
// `Input_Event` and `true` once a complete event has been recognized, or
// `false` while more bytes are still needed.
input_push_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	if state.state == .Paste {
		return _handle_paste_byte(state, b)
	}
	switch state.state {
	case .Ready:
		return _handle_ready_byte(state, b)
	case .Escape:
		return _handle_escape_byte(state, b)
	case .CSI:
		return _handle_csi_byte(state, b)
	case .SS3:
		return _handle_ss3_byte(state, b)
	case .Paste:
	}
	return nil, false
}

// input_flush force-resolves a pending partial sequence when the caller's own
// poll loop has timed out with no more bytes arriving (e.g. to disambiguate a
// lone `Escape` key press from the start of an escape sequence). The package
// itself never owns a clock; the caller decides when to call this.
input_flush :: proc(state: ^Input_State) -> (Input_Event, bool) {
	switch state.state {
	case .Escape:
		state.state = .Ready
		return Key_Event{code = .Escape, event_type = .Press}, true
	case .CSI, .SS3:
		raw := make([]byte, state.csi_len)
		copy(raw, state.csi_body[:state.csi_len])
		state.state = .Ready
		state.csi_len = 0
		return Unknown_Event{raw = raw}, true
	case .Paste:
		raw := _clone_bytes(state.paste_buf[:])
		clear(&state.paste_buf)
		state.state = .Ready
		return Unknown_Event{raw = raw}, true
	case .Ready:
		if state.utf8_expected > 0 {
			raw := _clone_bytes(state.utf8_buf[:state.utf8_len])
			state.utf8_len = 0
			state.utf8_expected = 0
			return Unknown_Event{raw = raw}, true
		}
	}
	return nil, false
}

@(private)
_handle_ready_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	if state.utf8_expected > 0 {
		if b & 0xC0 != 0x80 {
			state.utf8_len = 0
			state.utf8_expected = 0
			return _handle_ready_byte(state, b)
		}
		state.utf8_buf[state.utf8_len] = b
		state.utf8_len += 1
		if state.utf8_len < state.utf8_expected {
			return nil, false
		}
		r, _ := utf8.decode_rune(string(state.utf8_buf[:state.utf8_len]))
		state.utf8_len = 0
		state.utf8_expected = 0
		return Key_Event{code = .Char, char = r, event_type = .Press}, true
	}

	switch {
	case b == 0x1b:
		state.state = .Escape
		return nil, false
	case b == 0x0d:
		return Key_Event{code = .Enter, char = '\r', event_type = .Press}, true
	case b == 0x09:
		return Key_Event{code = .Tab, char = '\t', event_type = .Press}, true
	case b == 0x7f || b == 0x08:
		return Key_Event{code = .Backspace, event_type = .Press}, true
	case b == 0x00:
		return Key_Event{code = .Char, char = ' ', modifiers = {.Ctrl}, event_type = .Press}, true
	case b < 0x20:
		if ch, ok := _ctrl_byte_to_char(b); ok {
			return Key_Event{code = .Char, char = ch, modifiers = {.Ctrl}, event_type = .Press},
				true
		}
		return _single_byte_unknown(b), true
	case b < 0x80:
		return Key_Event{code = .Char, char = rune(b), event_type = .Press}, true
	case b >= 0xC0 && b < 0xE0:
		state.utf8_buf[0] = b
		state.utf8_len = 1
		state.utf8_expected = 2
		return nil, false
	case b >= 0xE0 && b < 0xF0:
		state.utf8_buf[0] = b
		state.utf8_len = 1
		state.utf8_expected = 3
		return nil, false
	case b >= 0xF0 && b < 0xF8:
		state.utf8_buf[0] = b
		state.utf8_len = 1
		state.utf8_expected = 4
		return nil, false
	case:
		return _single_byte_unknown(b), true
	}
}

@(private)
_handle_escape_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	switch b {
	case '[':
		state.state = .CSI
		state.csi_len = 0
		return nil, false
	case 'O':
		state.state = .SS3
		return nil, false
	case 0x1b:
		state.state = .Ready
		return Key_Event{code = .Escape, modifiers = {.Alt}, event_type = .Press}, true
	case:
		state.state = .Ready
		event, ok := _handle_ready_byte(state, b)
		if !ok {
			// Started a UTF-8/nested sequence right after Alt; modifier is lost
			// for that rare case, but the byte itself is not.
			return event, ok
		}
		if key, is_key := event.(Key_Event); is_key {
			key.modifiers += {.Alt}
			return key, true
		}
		return event, true
	}
}

@(private)
_handle_ss3_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	state.state = .Ready
	if code, ok := _letter_key_code(b); ok {
		return Key_Event{code = code, event_type = .Press}, true
	}
	return _single_byte_unknown(b), true
}

@(private)
_is_csi_final_byte :: proc(b: byte) -> bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '~'
}

@(private)
_handle_csi_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	if state.csi_len >= len(state.csi_body) {
		raw := make([]byte, state.csi_len)
		copy(raw, state.csi_body[:state.csi_len])
		state.state = .Ready
		state.csi_len = 0
		return Unknown_Event{raw = raw}, true
	}

	state.csi_body[state.csi_len] = b
	state.csi_len += 1

	if !_is_csi_final_byte(b) {
		return nil, false
	}

	state.state = .Ready
	body := state.csi_body[:state.csi_len]
	final := body[len(body) - 1]
	rest := body[:len(body) - 1]
	state.csi_len = 0

	private: byte = 0
	if len(rest) > 0 && (rest[0] == '?' || rest[0] == '<') {
		private = rest[0]
		rest = rest[1:]
	}

	if private == '<' {
		return _handle_mouse_final(rest, final)
	}

	fields, count, ok := _parse_csi_fields(string(rest))
	if !ok {
		return Unknown_Event{raw = _clone_bytes(body)}, true
	}

	switch final {
	case '~':
		if count > 0 && fields[0].value == 200 {
			clear(&state.paste_buf)
			state.state = .Paste
			return nil, false
		}
		return _handle_tilde_final(fields, count, body)
	case 'u':
		return _handle_kitty_u_final(state, private, fields, count, body)
	case 'c':
		return _handle_da1_final(state, private)
	case 'Z':
		return Key_Event {
				code = .Tab,
				modifiers = _decode_modifiers(_modifier_value(fields, count)) + {.Shift},
				event_type = _decode_event_type(_modifier_sub(fields, count)),
			},
			true
	case 'A', 'B', 'C', 'D', 'H', 'F', 'P', 'Q', 'S':
		code, code_ok := _letter_key_code(final)
		if !code_ok {
			return Unknown_Event{raw = _clone_bytes(body)}, true
		}
		return Key_Event {
				code = code,
				modifiers = _decode_modifiers(_modifier_value(fields, count)),
				event_type = _decode_event_type(_modifier_sub(fields, count)),
			},
			true
	case:
		return Unknown_Event{raw = _clone_bytes(body)}, true
	}
}

// Legacy `CSI [1;mod] {letter}` forms carry the modifier as the second field
// when present, otherwise the sequence has no modifier at all.
@(private)
_modifier_value :: proc(fields: [8]Csi_Field, count: int) -> int {
	if count >= 2 {
		return fields[1].value
	}
	return 1
}

@(private)
_modifier_sub :: proc(fields: [8]Csi_Field, count: int) -> (int, bool) {
	if count >= 2 {
		return fields[1].sub, fields[1].has_sub
	}
	return 0, false
}

@(private)
_handle_tilde_final :: proc(
	fields: [8]Csi_Field,
	count: int,
	body: []byte,
) -> (
	Input_Event,
	bool,
) {
	if count == 0 {
		return Unknown_Event{raw = _clone_bytes(body)}, true
	}
	code, ok := _tilde_key_code(fields[0].value)
	if !ok {
		return Unknown_Event{raw = _clone_bytes(body)}, true
	}
	sub, has_sub := _modifier_sub(fields, count)
	return Key_Event {
			code = code,
			modifiers = _decode_modifiers(_modifier_value(fields, count)),
			event_type = _decode_event_type(sub, has_sub),
		},
		true
}

@(private)
_handle_kitty_u_final :: proc(
	state: ^Input_State,
	private: byte,
	fields: [8]Csi_Field,
	count: int,
	body: []byte,
) -> (
	Input_Event,
	bool,
) {
	if private == '?' {
		// Kitty flags-query reply: `CSI ? <flags> u`. Presence alone proves
		// the terminal implements the protocol.
		state.protocol = .Kitty
		state.awaiting_negotiation = false
		return nil, false
	}
	if count == 0 {
		return Unknown_Event{raw = _clone_bytes(body)}, true
	}

	code, is_functional := _functional_key_code(fields[0].value)
	sub, has_sub := _modifier_sub(fields, count)
	event := Key_Event {
		modifiers  = _decode_modifiers(_modifier_value(fields, count)),
		event_type = _decode_event_type(sub, has_sub),
	}
	if is_functional {
		event.code = code
	} else {
		event.code = .Char
		event.char = rune(fields[0].value)
	}
	return event, true
}

@(private)
_handle_da1_final :: proc(state: ^Input_State, private: byte) -> (Input_Event, bool) {
	if state.awaiting_negotiation {
		// DA1 answered without a prior Kitty flags-query reply: not supported.
		if state.protocol != .Kitty {
			state.protocol = .CSI_U
		}
		state.awaiting_negotiation = false
	}
	return nil, false
}

@(private)
_handle_mouse_final :: proc(rest: []byte, final: byte) -> (Input_Event, bool) {
	raw := make([]byte, 3 + len(rest) + 1, context.temp_allocator)
	raw[0] = 0x1b
	raw[1] = '['
	raw[2] = '<'
	copy(raw[3:], rest)
	raw[len(raw) - 1] = final
	event, err := console.parse_sgr_mouse_event_response(string(raw))
	if err != .None {
		return Unknown_Event{raw = _clone_bytes(rest)}, true
	}
	return event, true
}

@(private)
_handle_paste_byte :: proc(state: ^Input_State, b: byte) -> (Input_Event, bool) {
	append(&state.paste_buf, b)
	if len(state.paste_buf) < len(PASTE_TERMINATOR) {
		return nil, false
	}
	tail := state.paste_buf[len(state.paste_buf) - len(PASTE_TERMINATOR):]
	if string(tail) != PASTE_TERMINATOR {
		return nil, false
	}
	text := string(state.paste_buf[:len(state.paste_buf) - len(PASTE_TERMINATOR)])
	clone := make([]byte, len(text))
	copy(clone, text)
	clear(&state.paste_buf)
	state.state = .Ready
	return Paste_Event{text = string(clone)}, true
}

@(private)
_clone_bytes :: proc(b: []byte) -> []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

@(private)
_single_byte_unknown :: proc(b: byte) -> Unknown_Event {
	out := make([]byte, 1)
	out[0] = b
	return Unknown_Event{raw = out}
}

@(private)
_parse_csi_fields :: proc(s: string) -> (fields: [8]Csi_Field, count: int, ok: bool) {
	if len(s) == 0 {
		return fields, 0, true
	}
	index := 0
	for {
		value := 0
		for index < len(s) && s[index] >= '0' && s[index] <= '9' {
			value = value * 10 + int(s[index] - '0')
			index += 1
		}
		field := Csi_Field {
			value = value,
		}
		if index < len(s) && s[index] == ':' {
			index += 1
			sub_value := 0
			for index < len(s) && s[index] >= '0' && s[index] <= '9' {
				sub_value = sub_value * 10 + int(s[index] - '0')
				index += 1
			}
			field.sub = sub_value
			field.has_sub = true
			for index < len(s) && s[index] != ';' {
				index += 1
			}
		}
		if count >= len(fields) {
			return fields, count, false
		}
		fields[count] = field
		count += 1
		if index >= len(s) {
			break
		}
		if s[index] != ';' {
			return fields, count, false
		}
		index += 1
		if index == len(s) {
			break
		}
	}
	return fields, count, true
}
