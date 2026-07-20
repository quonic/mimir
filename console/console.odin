package console

import "core:io"
import "core:os"

// Console codes for Linux terminals
// These codes are used to control the behavior of the terminal, such as clearing the screen, moving the cursor, changing text color, etc.
// This package implements all Linux supported console codes found in `man console_codes`

escape :: "\x1b"
csi_prefix :: escape + "["

Color :: enum int {
	Black          = 30,
	Red            = 31,
	Green          = 32,
	Yellow         = 33,
	Blue           = 34,
	Magenta        = 35,
	Cyan           = 36,
	White          = 37,
	Bright_Black   = 90,
	Bright_Red     = 91,
	Bright_Green   = 92,
	Bright_Yellow  = 93,
	Bright_Blue    = 94,
	Bright_Magenta = 95,
	Bright_Cyan    = 96,
	Bright_White   = 97,
}

Text_Attribute :: enum int {
	Reset        = 0,
	Bold         = 1,
	Dim          = 2,
	Italic       = 3,
	Underline    = 4,
	Blink        = 5,
	Reverse      = 7,
	Normal       = 22,
	No_Italic    = 23,
	No_Underline = 24,
	No_Blink     = 25,
	No_Reverse   = 27,
}

Style :: struct {
	foreground:     Color,
	background:     Color,
	use_foreground: bool,
	use_background: bool,
	attributes:     []Text_Attribute,
}

default_writer :: proc() -> io.Writer {
	return os.to_writer(os.stdout)
}

write_to :: proc(sequence: string, writer: io.Writer) -> (int, io.Error) {
	return io.write_string(writer, sequence)
}

write_stdout :: proc(sequence: string) -> (int, io.Error) {
	return write_to(sequence, default_writer())
}

write :: proc {
	write_stdout,
	write_to,
}

reset_sequence :: proc() -> string {
	return csi_prefix + "0m"
}

reset :: proc() -> (int, io.Error) {
	return write(reset_sequence())
}

positive_count :: proc(value: int) -> int {
	if value < 1 {
		return 1
	}
	return value
}

positive_coordinate :: proc(value: int) -> int {
	if value < 1 {
		return 1
	}
	return value
}

background_code :: proc(color: Color) -> int {
	code := int(color)
	if code >= 90 {
		return 100 + (code - 90)
	}
	return 40 + (code - 30)
}
