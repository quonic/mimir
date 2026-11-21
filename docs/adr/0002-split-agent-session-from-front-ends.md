# 0002: Split the agent session from its front ends

- Status: Accepted
- Date: 2026-11-21

## Context

Mimir will get an Agent Client Protocol (ACP) mode, `mimir --acp`, so that
editors can run it as a local agent. In ACP, work arrives and results leave as
JSON-RPC messages, not as terminal input and screen output.

The agent loop is currently part of the terminal UI state, `App_State`
(`app.odin`):

- `app_apply_agent_event`, `app_dispatch_agent_tool_request` and
  `app_start_agent_host_stream` (`agent_host.odin`) write agent output to
  `state.history` and `state.status` as display text, for example
  `read_file: x (running)`.
- The conversation sent to the model is rebuilt from `state.history` at the
  start of each turn (`app_build_ai_messages`).
- The approval flow (`app_show_approval`, `app_apply_approval_method` and
  `app_apply_approval_choice` in `app.odin`) pushes an `Approval_Overlay` and
  keeps the pending call in `state.approval`.
- The tool worker thread receives a `^App_State` and reads `dispatcher`,
  `skills` and `codeIndex` from it (`tool_execution_worker_proc`), while the
  main thread continues to change `App_State`.
- A process has one of each: one working directory, one dispatcher, one agent
  host, one tool execution and one pending approval.

ACP needs things that this structure cannot give:

- More than one session in a process, each with its own `cwd`.
- Agent output as typed data (message chunks, tool calls, tool call updates,
  usage), not as formatted history lines.
- Approvals that a remote client answers later, not an overlay.
- A turn result (ended, canceled, failed) for the `session/prompt` response.

The headless JSONL harness (`headless_runner.odin`) uses `App_State` directly.
That is correct for a harness that tests the UI, but it is not a model for ACP.

## Decision

Move the agent loop out of `App_State` into a new `session` package. A front
end (the terminal UI now, ACP later) owns one or more sessions, drives them,
and drains their events. The front end is the sink: it turns events into
history lines and overlays, or into ACP messages.

### What a session owns

A `Session` holds all state for one conversation in one working directory:

- The project root, from the working directory or from the ACP `cwd`.
- The tool dispatcher and its session grants.
- The skill registry and the code index for that project root.
- The agent host: runtime, active agent, subagent stack, usage and context
  window size.
- The tool execution worker.
- The pending approval and the approval safety classifier state.
- The transcript of completed turns.
- The selected model and the approval method. These start from the config, and
  a front end can change them for one session only.

Process-wide state stays outside the session and is shared by reference:
`settings.Mimir_Config` (providers, defaults and persistent permission grants)
and the config home directory.

The `session` package must not import `console`, `widgets`, `text_input` or any
type from package `main`. The compiler then enforces the boundary.
`Approval_Choice` moves from `app.odin` to the `session` package.

### Interface

The names below show the shape of the interface. Final names follow the code
style in `AGENTS.md`.

```odin
session_create :: proc(
	config: ^settings.Mimir_Config,
	options: Session_Options, // projectRoot, configHome, model, approvalMethod
	allocator := context.allocator,
) -> (^Session, Session_Error)
session_destroy :: proc(session: ^Session)

session_submit :: proc(session: ^Session, text: string) -> Session_Error
session_cancel :: proc(session: ^Session) -> Session_Error
session_resolve_approval :: proc(
	session: ^Session,
	toolCallID: string,
	choice: Approval_Choice,
) -> Session_Error

// Advances the stream, the tool worker and the safety classifier.
session_poll :: proc(session: ^Session) -> bool
session_next_event :: proc(session: ^Session) -> (Session_Event, bool)
session_event_destroy :: proc(event: ^Session_Event, allocator := context.allocator)
```

A session runs one turn at a time. `session_submit` returns `.Busy` while a
turn is active. This matches the current terminal behavior and ACP v1.

### Events

Events carry data, not display text. Formatting such as
`app_tool_history_content` and `approval_display_text` stays in the front end.
A tool call is identified by the model's tool request ID. A session has at most
one pending approval, so approvals use the same ID.

Each event below lists its data, what the terminal UI does with it, and what
the ACP front end sends.

- `Message_Delta`
  - Data: text, subagent depth.
  - Terminal UI: append to the assistant entry.
  - ACP: `agent_message_chunk`, or content of the subagent's tool call.
- `Thinking_Changed`
  - Data: thinking flag.
  - Terminal UI: status text and spinner.
  - ACP: nothing for now.
- `Usage_Updated`
  - Data: used tokens, context window size.
  - Terminal UI: status bar.
  - ACP: `usage_update`.
- `Tool_Call_Started`
  - Data: tool call ID, tool ID, target, raw arguments.
  - Terminal UI: append a tool history line.
  - ACP: `tool_call`.
- `Tool_Call_Updated`
  - Data: tool call ID, status, output, file diff.
  - Terminal UI: update the tool history line.
  - ACP: `tool_call_update`.
- `Approval_Requested`
  - Data: tool call ID, permission action, safety verdict.
  - Terminal UI: push the approval overlay.
  - ACP: `session/request_permission`.
- `Approval_Safety_Updated`
  - Data: tool call ID, safety verdict.
  - Terminal UI: update the overlay.
  - ACP: see Consequences.
- `Approval_Resolved`
  - Data: tool call ID, choice.
  - Terminal UI: pop the overlay.
  - ACP: nothing, or `$/cancel_request` if the permission request is still
    open.
- `Subagent_Started`
  - Data: parent tool call ID, task.
  - Terminal UI: history line.
  - ACP: content of the `run_subagent` tool call.
- `Subagent_Finished`
  - Data: parent tool call ID, result, failed flag.
  - Terminal UI: history line.
  - ACP: update of the `run_subagent` tool call.
- `Turn_Ended`
  - Data: reason (`Completed`, `Canceled` or `Failed`), error text.
  - Terminal UI: status text.
  - ACP: `session/prompt` result, or an error response.
- `Notice`
  - Data: severity, text.
  - Terminal UI: status text.
  - ACP: stderr log for now.

Tool call status is an enum: `Awaiting_Approval`, `Running`, `Completed`,
`Failed`, `Denied`. ACP maps `Awaiting_Approval` to `pending` and `Denied` to
`failed`.

The agent runtime does not report a tool continuation limit as a separate
outcome today. When it does, `Turn_Ended` gets a `Limit_Reached` reason that
maps to the ACP stop reason `max_turn_requests`.

### Rules

- **Events are pulled.** The front end calls `session_next_event`, the same
  way the session calls `agent.runtime_next_event`. A session never calls
  front-end code, so a front end can call any session procedure while it
  handles an event.
- **The approval method runs inside the session.** `Approve_All` and
  `Deny_All` settle a call without an `Approval_Requested` event; the front end
  sees only `Tool_Call_Updated`. All other cases emit `Approval_Requested`.
  When the safety classifier finishes, the session emits
  `Approval_Safety_Updated`. Under `Approve_Safe`, a safe verdict approves the
  call inside the session and emits `Approval_Resolved`. Every front end then
  gets the same approval behavior from one implementation. This matters
  because approval is the safety boundary for tool use.
- **Grants keep their current scopes.** `Allow_Session` adds a grant to the
  session's dispatcher. `Allow_Always` appends the grant to the shared config
  and saves the config, as it does now.
- **Persistent grants are read through the shared config.** Dispatchers do not
  keep their own copy of `config.permissionGrants[:]`. With more than one
  dispatcher, an append through one would move the array and leave a stale
  slice in the others.
- **The transcript keeps current behavior.** The model receives the system
  prompt and the user and assistant text of earlier turns. Tool calls and
  results from earlier turns are not sent again. The difference is that the
  session stores this transcript itself and no longer reads UI history.
  Changing what earlier turns send is a separate decision.
- **The tool worker only uses session-owned state.** The worker gets the
  session's dispatcher, skill registry and code index. The session does not
  change them while a tool runs.
- **`system_prompt_effective` takes what it uses** (config, skills and project
  root) instead of `App_State`.

### Front ends

- **Terminal UI.** `App_State` keeps one `^Session`. The main loop calls
  `session_poll` and drains events into history, status text and overlays.
  Input, slash commands and the config screen stay in `App_State`. `/stop`
  calls `session_cancel`. When the config screen changes the model or the
  approval method, it updates the session too.
- **Headless JSONL harness.** Its interface does not change. It still drives
  `App_State`, so the existing headless tests also cover the refactor.
- **ACP.** A separate front end keeps a map from ACP `sessionId` to
  `^Session`. Its protocol details are documented separately.

### Migration

1. Add the `session` package, move the code into it, and change the terminal
   UI to drain events. Users see no change. `app_test.odin` and
   `headless_test.odin` pass. Tests in `agent_host_test.odin` that call the
   `app_*` agent procedures move to `session/session_test.odin` and test the
   event interface.
2. Read persistent grants through the shared config.
3. Add the ACP front end.

## Alternatives considered

- **One `App_State` per ACP session, with the ACP front end diffing
  `state.history`.** This needs no refactor, but ACP would have to parse
  display text, carry terminal, input and config-screen state it does not use,
  and work around overlays for approvals. The tool worker would still share
  `App_State` with the main thread. Rejected as fragile.
- **A callback sink: a struct of procedure pointers and a `rawptr`.** Events
  would arrive with no polling, but a callback can call back into the session
  while the session is changing its own state. It also differs from the pull
  model of the agent runtime. Rejected.
- **A separate agent loop for ACP.** Two copies of the approval and permission
  logic would drift apart. Rejected because approval is the safety boundary.
- **Keep the session code in package `main`.** The diff is smaller, but
  nothing stops session code from using `App_State` again, and that is how the
  current coupling happened. Rejected.

## Consequences

- `agent_host.odin`, `tool_orchestration.odin` and `approval_safety.odin`, and
  the approval flow in `app.odin`, move into the `session` package. Most of the
  change is moved code. `system_prompt.odin` changes its parameters.
- The terminal UI sets status text from events. Some status wording can
  change.
- Each session loads its own skill registry and code index for its project
  root. ACP sessions in different directories use more memory and indexing
  work.
- New tools that need application state must get it through the session. The
  tool worker no longer sees `App_State`.
- Because the session owns its transcript, saved sessions (ACP `session/load`)
  become possible later. That is not part of this decision.
- Under `Approve_Safe`, the ACP front end should wait for
  `Approval_Safety_Updated` before it sends `session/request_permission`.
  Otherwise the client can show a prompt that the session then approves by
  itself.
