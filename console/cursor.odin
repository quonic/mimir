package console

import "core:fmt"
import "core:io"

cursor_up_sequence :: proc(rows: int = 1) -> string {
	return fmt.tprintf("%s%dA", csi_prefix, positive_count(rows))
}

cursor_up :: proc(rows: int = 1) -> (int, io.Error) {
	return write(cursor_up_sequence(rows))
}

cursor_down_sequence :: proc(rows: int = 1) -> string {
	return fmt.tprintf("%s%dB", csi_prefix, positive_count(rows))
}

cursor_down :: proc(rows: int = 1) -> (int, io.Error) {
	return write(cursor_down_sequence(rows))
}

cursor_right_sequence :: proc(columns: int = 1) -> string {
	return fmt.tprintf("%s%dC", csi_prefix, positive_count(columns))
}

cursor_right :: proc(columns: int = 1) -> (int, io.Error) {
	return write(cursor_right_sequence(columns))
}

cursor_left_sequence :: proc(columns: int = 1) -> string {
	return fmt.tprintf("%s%dD", csi_prefix, positive_count(columns))
}

cursor_left :: proc(columns: int = 1) -> (int, io.Error) {
	return write(cursor_left_sequence(columns))
}

cursor_goto_sequence :: proc(row, column: int) -> string {
	return fmt.tprintf(
		"%s%d;%dH",
		csi_prefix,
		positive_coordinate(row),
		positive_coordinate(column),
	)
}

cursor_goto :: proc(row, column: int) -> (int, io.Error) {
	return write(cursor_goto_sequence(row, column))
}

cursor_home_sequence :: proc() -> string {
	return cursor_goto_sequence(1, 1)
}

cursor_home :: proc() -> (int, io.Error) {
	return write(cursor_home_sequence())
}

cursor_to_row_sequence :: proc(row: int) -> string {
	return fmt.tprintf("%s%dd", csi_prefix, positive_coordinate(row))
}

cursor_to_row :: proc(row: int) -> (int, io.Error) {
	return write(cursor_to_row_sequence(row))
}

cursor_to_column_sequence :: proc(column: int) -> string {
	return fmt.tprintf("%s%dG", csi_prefix, positive_coordinate(column))
}

cursor_to_column :: proc(column: int) -> (int, io.Error) {
	return write(cursor_to_column_sequence(column))
}

cursor_save_sequence :: proc() -> string {
	return csi_prefix + "s"
}

cursor_save :: proc() -> (int, io.Error) {
	return write(cursor_save_sequence())
}

cursor_restore_sequence :: proc() -> string {
	return csi_prefix + "u"
}

cursor_restore :: proc() -> (int, io.Error) {
	return write(cursor_restore_sequence())
}

cursor_hide_sequence :: proc() -> string {
	return csi_prefix + "?25l"
}

cursor_hide :: proc() -> (int, io.Error) {
	return write(cursor_hide_sequence())
}

cursor_show_sequence :: proc() -> string {
	return csi_prefix + "?25h"
}

cursor_show :: proc() -> (int, io.Error) {
	return write(cursor_show_sequence())
}
