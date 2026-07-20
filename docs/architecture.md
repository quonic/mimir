# Architecture

## Terminal Application

Mimir is implemented as a full-screen terminal application that uses the
terminal alternate buffer for normal interactive sessions. Its primary view has
three parts:

- A history panel that takes most of the available height.
- A multiline input panel below history that expands as text is typed or pasted.
- A one-line status bar fixed to the final terminal row.

Slash commands are reserved for application commands. Initial command targets
include `/exit`, `/config`, `/help`, `/models`, `/skills`, and `/stop`.

## Input and Terminal Behavior

The input panel supports shell-style editing controls. Up and Down browse
submitted input history, while Left and Right move the insertion cursor within
the current input. The cursor is drawn inside the input panel as a blinking
background-colored cell.

The application enters raw mode and the alternate buffer, renders the panels,
and restores the terminal on `/exit`, Ctrl-C, or Ctrl-D. On Linux, it reads the
terminal size with `ioctl(TIOCGWINSZ)` and polls for input with a short timeout
so resizes redraw the layout even when no key is pressed. If size detection is
unavailable, it falls back to `LINES` and `COLUMNS`, then to 24 by 80.

## Chat Streaming and Cancellation

Chat submissions stream assistant responses from the configured provider and
model on a background worker, allowing the input loop to continue processing
terminal events. `/stop` and `/cancel` request graceful cancellation.

Cancellation completes after the provider emits the next stream chunk because
the current HTTP transport does not expose a hard request-abort hook.
