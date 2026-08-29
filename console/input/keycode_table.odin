package input

// Numeric key codes shared by the `~`-terminated legacy form and the Kitty
// `u`-terminated form (Kitty reuses the same numbers for these keys).
@(private)
_tilde_key_code :: proc(value: int) -> (Key_Code, bool) {
	switch value {
	case 2:
		return .Insert, true
	case 3:
		return .Delete, true
	case 5:
		return .Page_Up, true
	case 6:
		return .Page_Down, true
	case 1, 7:
		return .Home, true
	case 4, 8:
		return .End, true
	case 11:
		return .F1, true
	case 12:
		return .F2, true
	case 13:
		return .F3, true
	case 14:
		return .F4, true
	case 15:
		return .F5, true
	case 17:
		return .F6, true
	case 18:
		return .F7, true
	case 19:
		return .F8, true
	case 20:
		return .F9, true
	case 21:
		return .F10, true
	case 23:
		return .F11, true
	case 24:
		return .F12, true
	case 29:
		return .Menu, true
	case:
		return .None, false
	}
}

// Private-Use-Area and low-value key codes used in the Kitty `u`-terminated
// form for keys that have no legacy/tilde encoding.
@(private)
_functional_key_code :: proc(value: int) -> (Key_Code, bool) {
	switch value {
	case 13:
		return .Enter, true
	case 9:
		return .Tab, true
	case 27:
		return .Escape, true
	case 127:
		return .Backspace, true
	case 57358:
		return .Caps_Lock, true
	case 57359:
		return .Scroll_Lock, true
	case 57360:
		return .Num_Lock, true
	case 57361:
		return .Print_Screen, true
	case 57362:
		return .Pause, true
	case 57363:
		return .Menu, true
	case 57428:
		return .Media_Play, true
	case 57429:
		return .Media_Pause, true
	case 57430:
		return .Media_Play_Pause, true
	case 57431:
		return .Media_Reverse, true
	case 57432:
		return .Media_Stop, true
	case 57433:
		return .Media_Fast_Forward, true
	case 57434:
		return .Media_Rewind, true
	case 57435:
		return .Media_Track_Next, true
	case 57436:
		return .Media_Track_Previous, true
	case 57437:
		return .Media_Record, true
	case 57438:
		return .Lower_Volume, true
	case 57439:
		return .Raise_Volume, true
	case 57440:
		return .Mute_Volume, true
	case:
		return _tilde_key_code(value)
	}
}

// Legacy `CSI [1;mod] {letter}` / SS3 letter forms.
@(private)
_letter_key_code :: proc(letter: byte) -> (Key_Code, bool) {
	switch letter {
	case 'A':
		return .Arrow_Up, true
	case 'B':
		return .Arrow_Down, true
	case 'C':
		return .Arrow_Right, true
	case 'D':
		return .Arrow_Left, true
	case 'H':
		return .Home, true
	case 'F':
		return .End, true
	case 'P':
		return .F1, true
	case 'Q':
		return .F2, true
	case 'S':
		return .F4, true
	case:
		return .None, false
	}
}

// Reverse of Kitty's documented Ctrl mapping (Legacy ctrl mapping of ASCII
// keys table), covering the common `a`-`z` case used for keybindings.
@(private)
_ctrl_byte_to_char :: proc(b: byte) -> (rune, bool) {
	switch {
	case b >= 1 && b <= 26:
		return rune('a' + (b - 1)), true
	case b == 27:
		return '[', true
	case b == 28:
		return '\\', true
	case b == 29:
		return ']', true
	case b == 30:
		return '~', true
	case b == 31:
		return '_', true
	case:
		return 0, false
	}
}

@(private)
_decode_modifiers :: proc(value: int) -> Key_Modifiers {
	if value < 1 {
		return {}
	}
	bits := value - 1
	modifiers: Key_Modifiers
	if bits & 0x01 != 0 {
		modifiers += {.Shift}
	}
	if bits & 0x02 != 0 {
		modifiers += {.Alt}
	}
	if bits & 0x04 != 0 {
		modifiers += {.Ctrl}
	}
	if bits & 0x08 != 0 {
		modifiers += {.Super}
	}
	return modifiers
}

@(private)
_decode_event_type :: proc(sub: int, has_sub: bool) -> Key_Event_Type {
	if !has_sub {
		return .Press
	}
	switch sub {
	case 2:
		return .Repeat
	case 3:
		return .Release
	case:
		return .Press
	}
}
