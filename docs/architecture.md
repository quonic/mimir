# Architecture

## Terminal Application

Mimir is a full-screen terminal application. Interactive sessions use the
terminal alternate buffer. The main view has three parts:

- A history panel that uses most of the available height.
- A multiline input panel below the history panel. It expands as you type or paste text.
- A one-line status bar on the last terminal row.

Slash commands control the application. Commands include `/exit`, `/config`,
`/help`, `/stop`, and `/clear`.

## Input and Terminal Behavior

directory. `/clear` removes the submitted-input history for the current working
The input panel supports shell-style editing controls. Up and Down browse the
input history for the current working directory. `/clear` removes this history.
Left and Right move the cursor in the current input. The cursor appears as a
blinking cell in the input panel.

Mimir enters raw mode and the alternate buffer before it renders the panels. It
restores the terminal on `/exit`, Ctrl-C, or Ctrl-D. On Linux, it reads terminal
size with `ioctl(TIOCGWINSZ)`; on Windows, it reads `GetConsoleScreenBufferInfo`.
It polls for input with a short timeout so it can redraw after a resize. If it
cannot read the size, it uses `LINES` and `COLUMNS`. If those are unavailable,
it uses 24 by 80.

## Agent Sessions

The agent loop is in the `session` package, not in the terminal UI. A
`Session` holds one conversation in one project root: the agent runtime, the
tool dispatcher and its grants, the skills, the code index, the tool worker,
the pending approval and the transcript. The terminal UI (`App_State`) holds
one session. Its main loop calls `session_poll`, then drains the session
events into history lines, status text and the approval overlay
(`session_view.odin`). The session never calls front-end code, so the ACP
front end drives the same sessions. See
[ADR 0002](adr/0002-split-agent-session-from-front-ends.md) and the
[session package](packages/session.md).

## ACP Front End

`mimir --acp` (package `acp`) runs Mimir as an Agent Client Protocol agent over
stdio. A reader thread splits stdin into lines and queues them. The main loop
handles the queued messages, polls every session and turns its events into
ACP messages, then writes them to stdout. Stdout carries only protocol
messages: at startup `os.stdout` is pointed at stderr, so a stray print cannot
corrupt the stream. A `Connection` maps ACP session IDs to sessions; each
session has its own project root. See
[ADR 0003](adr/0003-acp-front-end.md) and
[Using Mimir From an Editor](acp.md).

## Chat Streaming and Cancellation

Chat requests stream assistant responses from the configured provider and model
on a background worker. The input loop continues to process terminal events.
`/stop` and `/cancel` request cancellation.

Cancellation aborts the active HTTP request. The transport checks for a
cancellation request at least once per second, so the stream stops within about
a second even when the provider sends no data.

All provider requests go through the `transport` package, which uses libcurl
from Odin's `vendor:curl`. See
[ADR 0001](adr/0001-use-libcurl-for-http.md).
