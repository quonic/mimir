// Package input turns raw terminal bytes into one unified stream of keyboard,
// mouse, paste, and unknown events, with Kitty keyboard protocol as the
// primary encoding, CSI-u (fixterms) as a passive fallback, and legacy VT
// sequences underneath both. See docs/packages/console-input.md for the
// negotiation flow and design rationale.
package input

import "../../console"

// Key_Code names every key this package can recognize, so callers never have
// to compare against raw codepoints or Private-Use-Area numbers themselves.
Key_Code :: enum int {
	None = 0,
	Char,
	Escape,
	Enter,
	Tab,
	Backspace,
	Insert,
	Delete,
	Home,
	End,
	Page_Up,
	Page_Down,
	Menu,
	Arrow_Up,
	Arrow_Down,
	Arrow_Right,
	Arrow_Left,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,
	Media_Play,
	Media_Pause,
	Media_Play_Pause,
	Media_Reverse,
	Media_Stop,
	Media_Fast_Forward,
	Media_Rewind,
	Media_Track_Next,
	Media_Track_Previous,
	Media_Record,
	Lower_Volume,
	Raise_Volume,
	Mute_Volume,
}

// Key_Modifier is intentionally limited to the four modifiers every tier
// (legacy, CSI-u, Kitty) can consistently report; see plan decision 16.
Key_Modifier :: enum int {
	Shift,
	Alt,
	Ctrl,
	Super,
}

Key_Modifiers :: bit_set[Key_Modifier]

Key_Event_Type :: enum int {
	Press = 0,
	Repeat,
	Release,
}

Key_Event :: struct {
	code:       Key_Code,
	char:       rune,
	modifiers:  Key_Modifiers,
	event_type: Key_Event_Type,
}

Paste_Event :: struct {
	text: string,
}

Unknown_Event :: struct {
	raw: []byte,
}

Input_Event :: union {
	Key_Event,
	console.Mouse_Event,
	Paste_Event,
	Unknown_Event,
}

// Protocol records which keyboard encoding the connected terminal has been
// found to use, after `input_begin_protocol_detection` negotiation completes.
Protocol :: enum int {
	Unknown = 0,
	Legacy,
	CSI_U,
	Kitty,
}

@(private)
Parse_State :: enum int {
	Ready = 0,
	Escape,
	CSI,
	SS3,
	Paste,
}

@(private)
CSI_BODY_CAP :: 64

@(private)
PASTE_TERMINATOR :: "\x1b[201~"

Input_State :: struct {
	protocol:             Protocol,
	awaiting_negotiation: bool,
	state:                Parse_State,
	csi_body:             [CSI_BODY_CAP]byte,
	csi_len:              int,
	utf8_buf:             [4]byte,
	utf8_len:             int,
	utf8_expected:        int,
	paste_buf:            [dynamic]byte,
}
