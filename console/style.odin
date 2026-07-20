package console

import "core:fmt"
import "core:io"
import "core:strings"

set_attributes_sequence :: proc(attributes: []Text_Attribute) -> string {
	if len(attributes) == 0 {
		return reset_sequence()
	}

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, csi_prefix)
	for index := 0; index < len(attributes); index += 1 {
		if index > 0 {
			strings.write_byte(&builder, ';')
		}
		strings.write_int(&builder, int(attributes[index]))
	}
	strings.write_byte(&builder, 'm')
	return strings.to_string(builder)
}

set_attributes :: proc(attributes: []Text_Attribute) -> (int, io.Error) {
	return write(set_attributes_sequence(attributes))
}

set_foreground_sequence :: proc(color: Color) -> string {
	return fmt.tprintf("%s%dm", csi_prefix, int(color))
}

set_foreground :: proc(color: Color) -> (int, io.Error) {
	return write(set_foreground_sequence(color))
}

set_foreground_default_sequence :: proc() -> string {
	return csi_prefix + "39m"
}

set_foreground_default :: proc() -> (int, io.Error) {
	return write(set_foreground_default_sequence())
}

set_background_sequence :: proc(color: Color) -> string {
	return fmt.tprintf("%s%dm", csi_prefix, background_code(color))
}

set_background :: proc(color: Color) -> (int, io.Error) {
	return write(set_background_sequence(color))
}

set_background_default_sequence :: proc() -> string {
	return csi_prefix + "49m"
}

set_background_default :: proc() -> (int, io.Error) {
	return write(set_background_default_sequence())
}

set_foreground_256_sequence :: proc(index: u8) -> string {
	return fmt.tprintf("%s38;5;%dm", csi_prefix, int(index))
}

set_foreground_256 :: proc(index: u8) -> (int, io.Error) {
	return write(set_foreground_256_sequence(index))
}

set_background_256_sequence :: proc(index: u8) -> string {
	return fmt.tprintf("%s48;5;%dm", csi_prefix, int(index))
}

set_background_256 :: proc(index: u8) -> (int, io.Error) {
	return write(set_background_256_sequence(index))
}

set_foreground_rgb_sequence :: proc(red, green, blue: u8) -> string {
	return fmt.tprintf("%s38;2;%d;%d;%dm", csi_prefix, int(red), int(green), int(blue))
}

set_foreground_rgb :: proc(red, green, blue: u8) -> (int, io.Error) {
	return write(set_foreground_rgb_sequence(red, green, blue))
}

set_background_rgb_sequence :: proc(red, green, blue: u8) -> string {
	return fmt.tprintf("%s48;2;%d;%d;%dm", csi_prefix, int(red), int(green), int(blue))
}

set_background_rgb :: proc(red, green, blue: u8) -> (int, io.Error) {
	return write(set_background_rgb_sequence(red, green, blue))
}

apply_style_sequence :: proc(style: Style) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, reset_sequence())
	if style.use_foreground {
		strings.write_string(&builder, set_foreground_sequence(style.foreground))
	}
	if style.use_background {
		strings.write_string(&builder, set_background_sequence(style.background))
	}
	if len(style.attributes) > 0 {
		strings.write_string(&builder, set_attributes_sequence(style.attributes))
	}
	return strings.to_string(builder)
}

apply_style :: proc(style: Style) -> (int, io.Error) {
	return write(apply_style_sequence(style))
}

styled_text_sequence :: proc(style: Style, text: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	strings.write_string(&builder, apply_style_sequence(style))
	strings.write_string(&builder, text)
	strings.write_string(&builder, reset_sequence())
	return strings.to_string(builder)
}

styled_text :: proc(style: Style, text: string) -> (int, io.Error) {
	return write(styled_text_sequence(style, text))
}
