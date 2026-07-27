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
size with `ioctl(TIOCGWINSZ)`. It polls for input with a short timeout so it can
redraw after a resize. If it cannot read the size, it uses `LINES` and `COLUMNS`.
If those are unavailable, it uses 24 by 80.

## Chat Streaming and Cancellation

Chat requests stream assistant responses from the configured provider and model
on a background worker. The input loop continues to process terminal events.
`/stop` and `/cancel` request cancellation.

Cancellation completes after the provider sends the next stream chunk. The HTTP
transport cannot abort an active request immediately.
