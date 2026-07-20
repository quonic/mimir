/*
Package `console` provides a small terminal-control layer for CLI and text UI
applications that want descriptive procedures instead of raw escape sequences.

The intended usage model has three output-oriented layers:

1. Direct write helpers

   Use procedures such as `cursor_up`, `clear_screen`, `set_foreground`,
   `set_insert_mode`, or `styled_text` when the caller simply wants the effect
   to be emitted to stdout immediately.

2. Sequence builders

   Use matching `_sequence` procedures such as `cursor_up_sequence` or
   `set_foreground_sequence` when the caller wants to compose terminal output,
   write to a custom `io.Writer`, or test exact emitted bytes.

There is now a third convenience layer for redraw-heavy text UI work:

3. Rendering helpers

  Use `Region`, `draw_frame_sequence`, `Batch`, and `Panel` when the caller
  wants to describe bounded redraws and framed sections without manually
  stitching together every cursor movement, fill operation, and title overlay.

Query helpers follow the same split, but the current query layer stops at
"emit + parse":

- Query emitters such as `cursor_position_query` and matching `_sequence`
  builders only write the request sequence.
- Parser helpers such as `parse_cursor_position_response` interpret terminal
  responses without performing any reads themselves.
- Mouse helpers follow the same stateless boundary, but expose mode toggles
  such as `set_mouse_tracking_sgr_sequence` plus parser helpers such as
  `parse_sgr_mouse_event_response` because mouse reporting is an ongoing input
  stream rather than a one-shot query.
- The current SGR mouse parser classifies the common xterm bit fields into
  `Mouse_Event.kind`, `Mouse_Event.button`, and modifier flags so callers do
  not need to decode raw button integers manually.
- Blocking reads and terminal input coordination are intentionally left to a
  later layer so the package does not hide TTY/input-loop assumptions.

In practice that means interactive mouse usage usually has three caller-owned
pieces above this package:

1. Terminal input setup such as raw mode.
2. A small byte buffer that collects terminal input until a complete mouse
  response is available.
3. Application-specific hit testing and state updates after a `Mouse_Event`
  has been parsed.

That means a caller that wants query information is expected to:

1. Emit a query sequence.
2. Capture the terminal response using its own input strategy.
3. Pass the captured response to a parser helper.

The package is intentionally stateless. It does not try to track terminal state,
cache modes, or infer what the terminal currently looks like. Callers are
expected to emit explicit setup and reset sequences when they care about the
resulting state.

Coordinate and count conventions:

- Public cursor coordinates are 1-based because terminal control sequences are
  1-based.
- Counts are clamped to a minimum of 1 for helpers such as cursor movement,
  character insertion/deletion, and line insertion/deletion.

Style usage:

- `Style` is intended for convenience helpers such as `apply_style` and
  `styled_text`.
- `Style.attributes` is a slice. If a caller stores or returns a `Style`, the
  slice backing storage must remain valid for as long as the `Style` is used.

Portability boundaries:

- The current public surface is centered on broadly ANSI/ECMA-48 style terminal
  controls: cursor movement, erase helpers, attributes, colors, display-mode
  toggles, and editing primitives.
- These helpers are suitable as a portable core for many ANSI-like terminals,
  but exact terminal behavior may still vary between Linux virtual consoles,
  xterm-compatible terminals, and integrated editor terminals.
- Some sequences have terminal-specific behavior even when the sequence itself
  is common. For example, scrollback clearing and display-mode interactions may
  differ across terminal implementations.
- Linux-console-specific controls described in `console_codes(4)` should be
  treated as a later, explicitly documented layer rather than assumed default
  behavior.
- Query response formats may also vary by terminal. The parser layer aims to
  accept common ANSI/DEC-style responses, while Linux console and xterm
  differences should be treated as documented variants rather than guaranteed
  identical behavior.

Recommended usage discipline:

- Prefer direct helpers for normal application code.
- Prefer `_sequence` helpers for composition, testing, and custom writers.
- Prefer `Batch` when several cursor/style operations should be emitted as one
  buffered update.
- Prefer `Panel` and `Region` helpers for framed sections and bounded redraws,
  while keeping application state management outside the package.
- Use `reset` when leaving styled or modeful regions.
- Keep terminal setup explicit rather than relying on ambient terminal state.
- For queries, keep response collection explicit rather than assuming the
  package can safely read from the same input path your application uses.
- For mouse tracking, explicitly enable the desired mode before interactive
  work and disable it again when leaving the region that expects mouse input.
- For SGR mouse responses, the parser recognizes the common modifier and event
  bits used by xterm-style terminals: shift `0x04`, alt `0x08`, control
  `0x10`, motion `0x20`, and wheel `0x40`.
- The parser returns semantic event data, but does not try to remember which
  panel, region, or widget the event belongs to. That decision remains in the
  caller layer.

Rendering helper notes:

- `Region` uses the same 1-based coordinate model as the cursor helpers and is
  normalized automatically so callers can pass edges in either order.
- `Batch` owns a `strings.Builder` and therefore has explicit lifecycle
  procedures: initialize with `batch_init`, reuse with `batch_reset`, and free
  owned memory with `batch_destroy`.
- `Panel` is intentionally draw-only. It helps with frames, titles, and
  interior fill, but does not manage focus, input, layout negotiation, or
  retained widget state.

Example:

	package main

	import "console"
	import "core:fmt"

	main :: proc() {
		style := console.Style{
			foreground     = .Bright_Cyan,
			use_foreground = true,
			attributes     = []console.Text_Attribute{.Bold},
		}

		console.clear_screen_home()
		console.styled_text(style, "status")
		fmt.println("")
		console.reset()
	}

Rendering example:

  package main

  import "console"

  main :: proc() {
    batch := console.batch_init()
    defer console.batch_destroy(&batch)

    panel := console.Panel {
      region        = console.Region{top_row = 2, left_column = 4, bottom_row = 6, right_column = 28},
      title         = "Status",
      fill_interior = true,
      interior_fill = ' ',
    }

    console.batch_draw_panel(&batch, panel)
    interior := console.panel_interior(panel)
    console.batch_move_to(&batch, interior.top_row, interior.left_column)
    console.batch_write_text(&batch, "ready")
    console.batch_emit(&batch)
  }

Query example:

  package main

  import "console"
  import "core:fmt"

  main :: proc() {
    // Emit the query.
    console.cursor_position_query()

    // Read the terminal response using application-specific input handling.
    response := "\x1b[24;13R"

    position, err := console.parse_cursor_position_response(response)
    if err == .None {
      fmt.printf("cursor at row=%d column=%d\n", position.row, position.column)
    }
  }

Mouse example:

  package main

  import "console"

  mouse_in_region :: proc(event: console.Mouse_Event, region: console.Region) -> bool {
    normalized := console.region_normalized(region)
    return event.row >= normalized.top_row &&
      event.row <= normalized.bottom_row &&
      event.column >= normalized.left_column &&
      event.column <= normalized.right_column
  }

  main :: proc() {
    region := console.Region{top_row = 4, left_column = 4, bottom_row = 10, right_column = 37}

    console.set_mouse_tracking_sgr(.Button, true)
    defer console.set_mouse_tracking_sgr(.Button, false)

    // Read terminal input using application-specific raw mode and buffering.
    response := "\x1b[<0;20;4M"

    event, err := console.parse_sgr_mouse_event_response(response)
    if err == .None && mouse_in_region(event, region) {
      // Update caller-owned application state for this region.
    }
  }

The root package demo in this repository follows exactly that model: raw input
and byte assembly stay outside the `console` package, while the package itself
only emits mouse mode sequences and parses completed terminal responses.
*/
package console
