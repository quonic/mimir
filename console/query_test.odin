package console

import "core:testing"

@(test)
test_query_sequences :: proc(t: ^testing.T) {
	assert_sequence(
		t,
		cursor_position_query_sequence(),
		"\x1b[6n",
		"expected cursor_position_query_sequence to request a cursor position report",
	)
	assert_sequence(
		t,
		device_status_query_sequence(),
		"\x1b[5n",
		"expected device_status_query_sequence to request a device status report",
	)
	assert_sequence(
		t,
		device_identification_query_sequence(),
		"\x1bZ",
		"expected device_identification_query_sequence to emit DECID",
	)
	assert_sequence(
		t,
		device_attributes_query_sequence(),
		"\x1b[c",
		"expected device_attributes_query_sequence to request device attributes",
	)
	assert_written_sequence(
		t,
		cursor_position_query_sequence(),
		"\x1b[6n",
		"expected cursor position query write to succeed",
		"expected cursor position query write to preserve the exact bytes",
	)
}

@(test)
test_parse_cursor_position_response :: proc(t: ^testing.T) {
	position, err := parse_cursor_position_response("\x1b[24;13R")
	assert(err == .None, "expected a valid CPR response to parse successfully")
	assert(
		position.row == 24 && position.column == 13,
		"expected CPR parser to extract row and column",
	)

	_, invalid_err := parse_cursor_position_response("\x1b[0;13R")
	assert(
		invalid_err == .Invalid_Response,
		"expected CPR parser to reject zero-based coordinates",
	)

	_, malformed_err := parse_cursor_position_response("\x1b[24R")
	assert(malformed_err == .Invalid_Response, "expected CPR parser to reject malformed responses")
	_ = t
}

@(test)
test_parse_device_status_response :: proc(t: ^testing.T) {
	healthy, err := parse_device_status_response("\x1b[0n")
	assert(err == .None, "expected a healthy DSR response to parse successfully")
	assert(healthy, "expected ESC[0n to indicate a healthy terminal")

	unhealthy, unhealthy_err := parse_device_status_response("\x1b[3n")
	assert(unhealthy_err == .None, "expected ESC[3n to be accepted as a status response")
	assert(!unhealthy, "expected ESC[3n to indicate a malfunctioning terminal")

	_, unsupported_err := parse_device_status_response("\x1b[7n")
	assert(
		unsupported_err == .Unsupported_Response,
		"expected unsupported DSR values to be reported explicitly",
	)
	_ = t
}

@(test)
test_parse_device_attributes_responses :: proc(t: ^testing.T) {
	linux_attrs, linux_err := parse_device_attributes_response("\x1b[?6c")
	assert(linux_err == .None, "expected a Linux console DA response to parse successfully")
	assert(linux_attrs.is_private, "expected Linux console DA response to be marked private")
	assert(
		linux_attrs.parameter_count == 1 && linux_attrs.parameters[0] == 6,
		"expected Linux console DA response to expose parameter 6",
	)

	xterm_attrs, xterm_err := parse_device_identification_response("\x1b[?1;2c")
	assert(xterm_err == .None, "expected an xterm DECID response to parse successfully")
	assert(xterm_attrs.is_private, "expected xterm DECID response to be marked private")
	assert(
		xterm_attrs.parameter_count == 2,
		"expected xterm DECID response to expose two parameters",
	)
	assert(
		xterm_attrs.parameters[0] == 1 && xterm_attrs.parameters[1] == 2,
		"expected xterm DECID response parameters to remain ordered",
	)

	_, invalid_err := parse_device_attributes_response("not a response")
	assert(
		invalid_err == .Invalid_Response,
		"expected malformed device attribute responses to be rejected",
	)
	_ = t
}
