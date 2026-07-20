package console

import "core:fmt"
import "core:io"

Mouse_Tracking_Mode :: enum int {
	Button = 1000,
	Drag   = 1002,
	Motion = 1003,
}

Mouse_Event_Kind :: enum int {
	Press = 0,
	Release,
	Motion,
	Wheel,
}

Mouse_Button :: enum int {
	None = 0,
	Left,
	Middle,
	Right,
	Wheel_Up,
	Wheel_Down,
	Wheel_Left,
	Wheel_Right,
}

Mouse_Event :: struct {
	row:          int,
	column:       int,
	kind:         Mouse_Event_Kind,
	button:       Mouse_Button,
	shift_down:   bool,
	alt_down:     bool,
	control_down: bool,
}

set_mouse_tracking_mode_sequence :: proc(mode: Mouse_Tracking_Mode, enabled: bool) -> string {
	if enabled {
		return fmt.tprintf("%s?%dh", csi_prefix, int(mode))
	}
	return fmt.tprintf("%s?%dl", csi_prefix, int(mode))
}

set_mouse_tracking_mode :: proc(mode: Mouse_Tracking_Mode, enabled: bool) -> (int, io.Error) {
	return write(set_mouse_tracking_mode_sequence(mode, enabled))
}

set_mouse_sgr_mode_sequence :: proc(enabled: bool) -> string {
	if enabled {
		return csi_prefix + "?1006h"
	}
	return csi_prefix + "?1006l"
}

set_mouse_sgr_mode :: proc(enabled: bool) -> (int, io.Error) {
	return write(set_mouse_sgr_mode_sequence(enabled))
}

set_mouse_tracking_sgr_sequence :: proc(mode: Mouse_Tracking_Mode, enabled: bool) -> string {
	tracking_sequence := set_mouse_tracking_mode_sequence(mode, enabled)
	sgr_sequence := set_mouse_sgr_mode_sequence(enabled)
	return fmt.tprintf("%s%s", tracking_sequence, sgr_sequence)
}

set_mouse_tracking_sgr :: proc(mode: Mouse_Tracking_Mode, enabled: bool) -> (int, io.Error) {
	return write(set_mouse_tracking_sgr_sequence(mode, enabled))
}

parse_sgr_mouse_event_response :: proc(response: string) -> (Mouse_Event, Query_Error) {
	event: Mouse_Event
	index, ok := _parse_csi_prefix(response)
	if !ok || index >= len(response) || response[index] != '<' {
		return event, .Invalid_Response
	}
	index += 1

	encoded, encoded_ok := _parse_decimal_value(response, &index)
	if !encoded_ok || index >= len(response) || response[index] != ';' {
		return event, .Invalid_Response
	}
	index += 1

	column, column_ok := _parse_decimal_value(response, &index)
	if !column_ok || index >= len(response) || response[index] != ';' {
		return event, .Invalid_Response
	}
	index += 1

	row, row_ok := _parse_decimal_value(response, &index)
	if !row_ok || index != len(response) - 1 {
		return event, .Invalid_Response
	}

	final := response[index]
	if final != 'M' && final != 'm' {
		return event, .Invalid_Response
	}
	if row < 1 || column < 1 {
		return event, .Invalid_Response
	}
	supported_mask := int(0x7f)
	if encoded < 0 || encoded & ~supported_mask != 0 {
		return event, .Unsupported_Response
	}

	event.row = row
	event.column = column
	event.shift_down = encoded & 0x04 != 0
	event.alt_down = encoded & 0x08 != 0
	event.control_down = encoded & 0x10 != 0

	button_code := encoded & 0x03
	is_motion := encoded & 0x20 != 0
	is_wheel := encoded & 0x40 != 0

	if is_wheel {
		if final != 'M' || is_motion {
			return Mouse_Event{}, .Unsupported_Response
		}
		button, button_ok := _parse_wheel_button(button_code)
		if !button_ok {
			return Mouse_Event{}, .Unsupported_Response
		}
		event.kind = .Wheel
		event.button = button
		return event, .None
	}

	if is_motion {
		if final != 'M' {
			return Mouse_Event{}, .Invalid_Response
		}
		button, button_ok := _parse_pointer_button(button_code, true)
		if !button_ok {
			return Mouse_Event{}, .Unsupported_Response
		}
		event.kind = .Motion
		event.button = button
		return event, .None
	}

	button, button_ok := _parse_pointer_button(button_code, false)
	if !button_ok {
		return Mouse_Event{}, .Unsupported_Response
	}
	if final == 'm' {
		event.kind = .Release
		event.button = button
		return event, .None
	}

	event.kind = .Press
	event.button = button
	return event, .None
}

@(private)
_parse_decimal_value :: proc(response: string, index: ^int) -> (int, bool) {
	if index^ >= len(response) || response[index^] < '0' || response[index^] > '9' {
		return 0, false
	}

	value := 0
	for index^ < len(response) {
		ch := response[index^]
		if ch < '0' || ch > '9' {
			break
		}
		value = value * 10 + int(ch - '0')
		index^ += 1
	}
	return value, true
}

@(private)
_parse_pointer_button :: proc(button_code: int, allow_none: bool) -> (Mouse_Button, bool) {
	switch button_code {
	case 0:
		return .Left, true
	case 1:
		return .Middle, true
	case 2:
		return .Right, true
	case 3:
		if allow_none {
			return .None, true
		}
		return .None, false
	case:
		return .None, false
	}
}

@(private)
_parse_wheel_button :: proc(button_code: int) -> (Mouse_Button, bool) {
	switch button_code {
	case 0:
		return .Wheel_Up, true
	case 1:
		return .Wheel_Down, true
	case 2:
		return .Wheel_Left, true
	case 3:
		return .Wheel_Right, true
	case:
		return .None, false
	}
}
