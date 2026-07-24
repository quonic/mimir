package console

import "core:encoding/base64"
import "core:fmt"
import "core:io"
import "core:strings"

set_insert_mode_sequence :: proc(enabled: bool) -> string {
	if enabled {
		return csi_prefix + "4h"
	}
	return csi_prefix + "4l"
}

set_insert_mode :: proc(enabled: bool) -> (int, io.Error) {
	return write(set_insert_mode_sequence(enabled))
}

set_bracketed_paste_mode_sequence :: proc(enabled: bool) -> string {
	if enabled {
		return csi_prefix + "?2004h"
	}
	return csi_prefix + "?2004l"
}

set_bracketed_paste_mode :: proc(enabled: bool) -> (int, io.Error) {
	return write(set_bracketed_paste_mode_sequence(enabled))
}

osc52_clipboard_sequence :: proc(text: string, allocator := context.allocator) -> string {
	encoded := base64.encode(transmute([]byte)text, allocator = allocator)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, escape + "]52;c;")
	strings.write_string(&builder, encoded)
	strings.write_string(&builder, "\a")
	return strings.to_string(builder)
}

osc52_copy_to_clipboard :: proc(text: string) -> (int, io.Error) {
	return write(osc52_clipboard_sequence(text))
}

set_autowrap_sequence :: proc(enabled: bool) -> string {
	if enabled {
		return csi_prefix + "?7h"
	}
	return csi_prefix + "?7l"
}

set_autowrap :: proc(enabled: bool) -> (int, io.Error) {
	return write(set_autowrap_sequence(enabled))
}

set_reverse_video_mode_sequence :: proc(enabled: bool) -> string {
	if enabled {
		return csi_prefix + "?5h"
	}
	return csi_prefix + "?5l"
}

set_reverse_video_mode :: proc(enabled: bool) -> (int, io.Error) {
	return write(set_reverse_video_mode_sequence(enabled))
}

begin_synchronized_update_sequence :: proc() -> string {
	return csi_prefix + "?2026h"
}

end_synchronized_update_sequence :: proc() -> string {
	return csi_prefix + "?2026l"
}

synchronized_output_sequence :: proc(sequence: string, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, begin_synchronized_update_sequence())
	strings.write_string(&builder, sequence)
	strings.write_string(&builder, end_synchronized_update_sequence())
	return strings.to_string(builder)
}

set_scroll_region_sequence :: proc(top_row, bottom_row: int) -> string {
	top := positive_coordinate(top_row)
	bottom := positive_coordinate(bottom_row)
	if bottom < top {
		bottom = top
	}
	return fmt.tprintf("%s%d;%dr", csi_prefix, top, bottom)
}

set_scroll_region :: proc(top_row, bottom_row: int) -> (int, io.Error) {
	return write(set_scroll_region_sequence(top_row, bottom_row))
}

reset_scroll_region_sequence :: proc() -> string {
	return csi_prefix + "r"
}

reset_scroll_region :: proc() -> (int, io.Error) {
	return write(reset_scroll_region_sequence())
}

enter_alternate_screen_sequence :: proc() -> string {
	return csi_prefix + "?1049h"
}

enter_alternate_screen :: proc() -> (int, io.Error) {
	return write(enter_alternate_screen_sequence())
}

exit_alternate_screen_sequence :: proc() -> string {
	return csi_prefix + "?1049l"
}

exit_alternate_screen :: proc() -> (int, io.Error) {
	return write(exit_alternate_screen_sequence())
}

terminal_app_start_sequence :: proc() -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, enter_alternate_screen_sequence())
	strings.write_string(&builder, cursor_hide_sequence())
	strings.write_string(&builder, clear_screen_home_sequence())
	return strings.to_string(builder)
}

terminal_app_stop_sequence :: proc() -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, end_synchronized_update_sequence())
	strings.write_string(&builder, reset_sequence())
	strings.write_string(&builder, cursor_show_sequence())
	strings.write_string(&builder, exit_alternate_screen_sequence())
	return strings.to_string(builder)
}
