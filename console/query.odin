package console

import "core:io"

Query_Error :: enum int {
	None = 0,
	Invalid_Response,
	Unsupported_Response,
	Io_Error,
	Timeout,
}

Cursor_Position :: struct {
	row:    int,
	column: int,
}

Device_Attributes :: struct {
	is_private:      bool,
	parameters:      [8]int,
	parameter_count: int,
}

_Parsed_Csi_Response :: struct {
	is_private:      bool,
	parameters:      [8]int,
	parameter_count: int,
}

cursor_position_query_sequence :: proc() -> string {
	return csi_prefix + "6n"
}

cursor_position_query :: proc() -> (int, io.Error) {
	return write(cursor_position_query_sequence())
}

device_status_query_sequence :: proc() -> string {
	return csi_prefix + "5n"
}

device_status_query :: proc() -> (int, io.Error) {
	return write(device_status_query_sequence())
}

device_identification_query_sequence :: proc() -> string {
	return escape + "Z"
}

device_identification_query :: proc() -> (int, io.Error) {
	return write(device_identification_query_sequence())
}

device_attributes_query_sequence :: proc() -> string {
	return csi_prefix + "c"
}

device_attributes_query :: proc() -> (int, io.Error) {
	return write(device_attributes_query_sequence())
}

parse_cursor_position_response :: proc(response: string) -> (Cursor_Position, Query_Error) {
	parsed, err := _parse_csi_numeric_response(response, 'R')
	if err != .None {
		return {}, err
	}
	if parsed.is_private || parsed.parameter_count != 2 {
		return {}, .Invalid_Response
	}
	if parsed.parameters[0] < 1 || parsed.parameters[1] < 1 {
		return {}, .Invalid_Response
	}
	return Cursor_Position{row = parsed.parameters[0], column = parsed.parameters[1]}, .None
}

parse_device_status_response :: proc(response: string) -> (healthy: bool, err: Query_Error) {
	parsed, parse_err := _parse_csi_numeric_response(response, 'n')
	if parse_err != .None {
		return false, parse_err
	}
	if parsed.is_private || parsed.parameter_count != 1 {
		return false, .Invalid_Response
	}
	switch parsed.parameters[0] {
	case 0:
		return true, .None
	case 3:
		return false, .None
	case:
		return false, .Unsupported_Response
	}
}

parse_device_attributes_response :: proc(response: string) -> (Device_Attributes, Query_Error) {
	parsed, err := _parse_csi_numeric_response(response, 'c')
	if err != .None {
		return {}, err
	}
	return Device_Attributes {
			is_private = parsed.is_private,
			parameters = parsed.parameters,
			parameter_count = parsed.parameter_count,
		},
		.None
}

parse_device_identification_response :: proc(
	response: string,
) -> (
	Device_Attributes,
	Query_Error,
) {
	return parse_device_attributes_response(response)
}

_parse_csi_numeric_response :: proc(
	response: string,
	final: byte,
) -> (
	_Parsed_Csi_Response,
	Query_Error,
) {
	parsed: _Parsed_Csi_Response
	index, ok := _parse_csi_prefix(response)
	if !ok {
		return parsed, .Invalid_Response
	}

	if index < len(response) && response[index] == '?' {
		parsed.is_private = true
		index += 1
	}

	current := 0
	has_digits := false
	for ; index < len(response); index += 1 {
		ch := response[index]
		switch {
		case ch >= '0' && ch <= '9':
			current = current * 10 + int(ch - '0')
			has_digits = true
		case ch == ';':
			if parsed.parameter_count >= len(parsed.parameters) {
				return parsed, .Unsupported_Response
			}
			if has_digits {
				parsed.parameters[parsed.parameter_count] = current
			} else {
				parsed.parameters[parsed.parameter_count] = 0
			}
			parsed.parameter_count += 1
			current = 0
			has_digits = false
		case ch == final && index == len(response) - 1:
			if has_digits || (index > 0 && response[index - 1] == ';') {
				if parsed.parameter_count >= len(parsed.parameters) {
					return parsed, .Unsupported_Response
				}
				if has_digits {
					parsed.parameters[parsed.parameter_count] = current
				} else {
					parsed.parameters[parsed.parameter_count] = 0
				}
				parsed.parameter_count += 1
			}
			return parsed, .None
		case:
			return parsed, .Invalid_Response
		}
	}

	return parsed, .Invalid_Response
}
