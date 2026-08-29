# Console Input Package

The `console/input` package turns raw terminal bytes into one unified stream
of `Input_Event`s: keyboard, mouse, bracketed paste, and unknown/malformed
sequences. It is the single input pipe `app.odin` uses for the Chat, Setup,
Approval, and Config modes.

It supports three keyboard encodings, from most to least capable:

1. **Kitty keyboard protocol** — press/repeat/release events, unambiguous
   escape codes.
2. **CSI-u (fixterms)** — recognized passively wherever a terminal emits it;
   never actively enabled (see "Why not `modifyOtherKeys`" below).
3. **Legacy VT sequences** — arrows, function keys, SS3 forms.

The package never performs its own I/O. Callers own the read loop and feed it
one byte at a time, mirroring the existing `console.mouse_input_push_byte`
precedent.

## Feeding bytes in

```odin
import input "console/input"

state: input.Input_State
event, ok := input.input_push_byte(&state, b)
if ok {
    switch e in event {
    case input.Key_Event:
        // e.code, e.char, e.modifiers, e.event_type
    case console.Mouse_Event:
        // reused unchanged from the console package
    case input.Paste_Event:
        // e.text is heap-owned; free it once consumed
        delete(e.text)
    case input.Unknown_Event:
        delete(e.raw)
    }
}
```

`input_push_byte` returns `ok == false` while a multi-byte sequence (escape
sequence, UTF-8 continuation, bracketed paste) is still being assembled.

## Resolving a pending sequence on timeout

The package never owns a clock. When the caller's own poll loop times out
with no more bytes arriving (e.g. to disambiguate a lone `Escape` key press
from the start of an escape sequence), call `input_flush`:

```odin
event, ok := input.input_flush(&state)
```

## Kitty protocol negotiation

Negotiation happens over the same byte-push pipe, not a separate blocking
read:

```odin
_, _ = console.write(input.input_begin_protocol_detection(&state))
// ... later, feed the terminal's reply bytes through input_push_byte as usual
```

This writes a Kitty progressive-enhancement flags query (`CSI = 3 ; 1 u`,
requesting only "disambiguate escape codes" + "report event types" — not
alternate keys, not "report all keys as escape codes", since that would stop
plain typed text from being sent as UTF-8) immediately followed by a primary
Device Attributes request used purely as a sentinel. If the terminal answers
the flags query, `state.protocol` becomes `.Kitty`. If only the DA1 sentinel
answers, `state.protocol` becomes `.CSI_U` (the passive fallback tier is
always active regardless of `state.protocol`; the field mainly exists so a
caller could report which tier is active).

## Why not `modifyOtherKeys`

CSI-u/fixterms has no enable sequence of its own — a terminal either emits it
natively or it doesn't. The only way to force more keys into that shape on a
non-Kitty terminal is xterm's `modifyOtherKeys`, which Kitty's own
specification argues against relying on (no release events, unspecified key
numbering, no reliable way to query it). This package only recognizes CSI-u
passively; it never sends `CSI > 4 ; 2 m`.

## Scope

- Modifiers are limited to `{Shift, Alt, Ctrl, Super}` — the set every tier
  can consistently report. Hyper/meta/caps-lock/num-lock are not exposed.
- Mouse tracking mode (SGR reporting) is not enabled by this package; that
  stays the caller's responsibility via `console.set_mouse_tracking_sgr`.
- Resize events are not part of `Input_Event`; they are not terminal input
  bytes and stay on the caller's own `SIGWINCH`/`ioctl` polling path.
