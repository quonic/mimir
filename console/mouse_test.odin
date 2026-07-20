package console

import "core:testing"

@(test)
test_mouse_mode_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		set_mouse_tracking_mode_sequence(.Button, true),
		"\x1b[?1000h",
		"expected set_mouse_tracking_mode_sequence(.Button, true) to enable button tracking",
	)
	assert_sequence(
		t,
		set_mouse_tracking_mode_sequence(.Motion, false),
		"\x1b[?1003l",
		"expected set_mouse_tracking_mode_sequence(.Motion, false) to disable motion tracking",
	)
	assert_sequence(
		t,
		set_mouse_sgr_mode_sequence(true),
		"\x1b[?1006h",
		"expected set_mouse_sgr_mode_sequence(true) to enable SGR mouse reporting",
	)
	assert_sequence(
		t,
		set_mouse_tracking_sgr_sequence(.Drag, true),
		"\x1b[?1002h\x1b[?1006h",
		"expected set_mouse_tracking_sgr_sequence to combine tracking and SGR enablement",
	)
	assert_sequence(
		t,
		set_mouse_tracking_sgr_sequence(.Drag, false),
		"\x1b[?1002l\x1b[?1006l",
		"expected set_mouse_tracking_sgr_sequence to combine tracking and SGR disablement",
	)
	assert_written_sequence(
		t,
		set_mouse_tracking_sgr_sequence(.Button, false),
		"\x1b[?1000l\x1b[?1006l",
		"expected mouse tracking disable sequence write to succeed",
		"expected mouse tracking disable sequence write to preserve exact bytes",
	)
}

@(test)
test_parse_sgr_mouse_event_response :: proc(t: ^testing.T) {
	press, press_err := parse_sgr_mouse_event_response("\x1b[<0;12;7M")
	assert(press_err == .None, "expected left-button press response to parse successfully")
	assert(press.kind == .Press, "expected final M to classify as a press event")
	assert(press.button == .Left, "expected button code 0 to map to left button")
	assert(press.column == 12 && press.row == 7, "expected parser to preserve mouse coordinates")

	release, release_err := parse_sgr_mouse_event_response("\x1b[<2;12;7m")
	assert(release_err == .None, "expected right-button release response to parse successfully")
	assert(release.kind == .Release, "expected final m to classify as a release event")
	assert(release.button == .Right, "expected button code 2 to map to right button")

	motion, motion_err := parse_sgr_mouse_event_response("\x1b[<39;40;9M")
	assert(motion_err == .None, "expected drag motion response to parse successfully")
	assert(motion.kind == .Motion, "expected motion bit to classify as a motion event")
	assert(
		motion.button == .None,
		"expected button code 3 motion to represent pointer movement with no button",
	)
	assert(motion.shift_down, "expected modifier bits to preserve shift state")

	wheel, wheel_err := parse_sgr_mouse_event_response("\x1b[<65;20;4M")
	assert(wheel_err == .None, "expected wheel response to parse successfully")
	assert(wheel.kind == .Wheel, "expected wheel bit to classify as a wheel event")
	assert(wheel.button == .Wheel_Down, "expected wheel button code 1 to map to wheel down")
	assert(wheel.column == 20 && wheel.row == 4, "expected wheel response to preserve coordinates")

	modifier_press, modifier_press_err := parse_sgr_mouse_event_response("\x1b[<28;123;456M")
	assert(
		modifier_press_err == .None,
		"expected modified button press response to parse successfully",
	)
	assert(
		modifier_press.button == .Left && modifier_press.kind == .Press,
		"expected modified press response to preserve base button semantics",
	)
	assert(modifier_press.shift_down, "expected modified press response to preserve shift state")
	assert(modifier_press.alt_down, "expected modified press response to preserve alt state")
	assert(
		modifier_press.control_down,
		"expected modified press response to preserve control state",
	)
	assert(
		modifier_press.column == 123 && modifier_press.row == 456,
		"expected parser to support multi-digit mouse coordinates",
	)

	alt_motion, alt_motion_err := parse_sgr_mouse_event_response("\x1b[<43;15;3M")
	assert(alt_motion_err == .None, "expected alt-modified motion response to parse successfully")
	assert(alt_motion.kind == .Motion, "expected motion bit to classify as motion")
	assert(alt_motion.alt_down, "expected alt-modified motion response to preserve alt state")
	assert(
		!alt_motion.shift_down,
		"expected alt-modified motion response to avoid false shift state",
	)
	assert(
		!alt_motion.control_down,
		"expected alt-modified motion response to avoid false control state",
	)

	_, invalid_err := parse_sgr_mouse_event_response("\x1b[<0;0;7M")
	assert(invalid_err == .Invalid_Response, "expected zero mouse coordinates to be rejected")

	_, invalid_final_err := parse_sgr_mouse_event_response("\x1b[<0;12;7x")
	assert(
		invalid_final_err == .Invalid_Response,
		"expected unsupported final bytes to be rejected as invalid responses",
	)

	_, missing_separator_err := parse_sgr_mouse_event_response("\x1b[<0;127M")
	assert(
		missing_separator_err == .Invalid_Response,
		"expected parser to reject missing SGR parameter separators",
	)

	_, extra_parameter_err := parse_sgr_mouse_event_response("\x1b[<0;12;7;4M")
	assert(
		extra_parameter_err == .Invalid_Response,
		"expected parser to reject extra SGR parameters",
	)

	_, malformed_err := parse_sgr_mouse_event_response("\x1b[0;12;7M")
	assert(
		malformed_err == .Invalid_Response,
		"expected parser to require SGR mouse prefix syntax",
	)

	_, wheel_release_err := parse_sgr_mouse_event_response("\x1b[<65;20;4m")
	assert(
		wheel_release_err == .Unsupported_Response,
		"expected wheel responses with release terminators to be reported unsupported",
	)

	_, wheel_motion_err := parse_sgr_mouse_event_response("\x1b[<97;20;4M")
	assert(
		wheel_motion_err == .Unsupported_Response,
		"expected wheel responses with motion bit set to be reported unsupported",
	)

	_, unsupported_err := parse_sgr_mouse_event_response("\x1b[<128;12;7M")
	assert(
		unsupported_err == .Unsupported_Response,
		"expected unsupported high-bit encodings to be reported",
	)
	_ = t
}
