package console

import "core:fmt"
import "core:io"
import "core:strings"

clear_screen_sequence :: proc() -> string {
	return csi_prefix + "2J"
}

clear_screen :: proc() -> (int, io.Error) {
	return write(clear_screen_sequence())
}

clear_scrollback_sequence :: proc() -> string {
	return csi_prefix + "3J"
}

clear_scrollback :: proc() -> (int, io.Error) {
	return write(clear_scrollback_sequence())
}

clear_to_end_of_screen_sequence :: proc() -> string {
	return csi_prefix + "J"
}

clear_to_end_of_screen :: proc() -> (int, io.Error) {
	return write(clear_to_end_of_screen_sequence())
}

clear_to_start_of_screen_sequence :: proc() -> string {
	return csi_prefix + "1J"
}

clear_to_start_of_screen :: proc() -> (int, io.Error) {
	return write(clear_to_start_of_screen_sequence())
}

clear_line_sequence :: proc() -> string {
	return csi_prefix + "2K"
}

clear_line :: proc() -> (int, io.Error) {
	return write(clear_line_sequence())
}

clear_to_start_of_line_sequence :: proc() -> string {
	return csi_prefix + "1K"
}

clear_to_start_of_line :: proc() -> (int, io.Error) {
	return write(clear_to_start_of_line_sequence())
}

clear_to_end_of_line_sequence :: proc() -> string {
	return csi_prefix + "K"
}

clear_to_end_of_line :: proc() -> (int, io.Error) {
	return write(clear_to_end_of_line_sequence())
}

insert_characters_sequence :: proc(count: int = 1) -> string {
	return fmt.tprintf("%s%d@", csi_prefix, positive_count(count))
}

insert_characters :: proc(count: int = 1) -> (int, io.Error) {
	return write(insert_characters_sequence(count))
}

delete_characters_sequence :: proc(count: int = 1) -> string {
	return fmt.tprintf("%s%dP", csi_prefix, positive_count(count))
}

delete_characters :: proc(count: int = 1) -> (int, io.Error) {
	return write(delete_characters_sequence(count))
}

erase_characters_sequence :: proc(count: int = 1) -> string {
	return fmt.tprintf("%s%dX", csi_prefix, positive_count(count))
}

erase_characters :: proc(count: int = 1) -> (int, io.Error) {
	return write(erase_characters_sequence(count))
}

insert_lines_sequence :: proc(count: int = 1) -> string {
	return fmt.tprintf("%s%dL", csi_prefix, positive_count(count))
}

insert_lines :: proc(count: int = 1) -> (int, io.Error) {
	return write(insert_lines_sequence(count))
}

delete_lines_sequence :: proc(count: int = 1) -> string {
	return fmt.tprintf("%s%dM", csi_prefix, positive_count(count))
}

delete_lines :: proc(count: int = 1) -> (int, io.Error) {
	return write(delete_lines_sequence(count))
}

clear_screen_home_sequence :: proc() -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, clear_screen_sequence())
	strings.write_string(&builder, cursor_home_sequence())
	return strings.to_string(builder)
}

clear_screen_home :: proc() -> (int, io.Error) {
	return write(clear_screen_home_sequence())
}
