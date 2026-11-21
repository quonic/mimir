# 0003: ACP front end (`mimir --acp`)

- Status: Accepted
- Date: 2026-11-21

## Context

[ADR-0002](0002-split-agent-session-from-front-ends.md) moves the agent loop
into a `session` package and says that the Agent Client Protocol (ACP) front
end "keeps a map from ACP `sessionId` to `^Session`" and that "its protocol
details are documented separately". This is that document. Issue #49 requires
it before the front end is implemented. The implementation is tracked in #50.

This ADR records decisions, not only a protocol reference: which ACP features
Mimir advertises, how ACP permission options map to `Approval_Choice`, which
error codes Mimir returns, and how the process reads stdin and polls sessions.
A user-facing page (`docs/acp.md`, how to run Mimir from an editor) comes with
the implementation.

### Protocol version used

ACP has one major protocol version, `1`, negotiated as the integer
`protocolVersion` in `initialize`. New features arrive as capabilities, not as
new versions. The sources for this document are:

- The v1 spec pages at <https://agentclientprotocol.com/protocol/v1/>
  (Initialization, Session Setup, Prompt Turn, Tool Calls, Request
  Cancellation, Errors, Transports, Subagents).
- The JSON schema `schema/v1/schema.json` and `schema/v1/meta.json` in
  <https://github.com/agentclientprotocol/agent-client-protocol> at tag
  `schema-v1.34.1` (2026-11-21, the latest stable schema release).

Schema `v2.0.0-beta.*` releases exist. They are pre-releases and are out of
scope. Field and method names below are copied from the `schema-v1.34.1`
schema.

### What the session gives the front end

ADR-0002 defines the interface: `session_create`, `session_destroy`,
`session_submit`, `session_cancel`, `session_resolve_approval`,
`session_poll`, `session_next_event` and `session_event_destroy`, and the
events `Message_Delta`, `Thinking_Changed`, `Usage_Updated`,
`Tool_Call_Started`, `Tool_Call_Updated`, `Approval_Requested`,
`Approval_Safety_Updated`, `Approval_Resolved`, `Subagent_Started`,
`Subagent_Finished`, `Turn_Ended` and `Notice`. #48 implements it in
parallel. This document designs against the ADR. Each detail that #48 has
not settled yet is listed in [Dependencies on #48](#dependencies-on-48).

## Decision

Add an `acp` package and a `--acp` command-line flag. `mimir --acp` loads the
shared config, speaks ACP v1 as the Agent over stdio, and runs any number of
sessions in one process.

### Package and entry point

- New package `acp/`. It imports `session`, `settings`, `tool_policy` and core
  packages. Like `session`, it must not import `console`, `widgets`,
  `text_input` or package `main`.
- `main.odin` checks for `--acp` before it starts the terminal UI, the same
  way it checks for `--headless-json`, and calls `acp.run`. `--acp` together
  with `--headless-json` is an error: Mimir writes a message to stderr and
  exits with status 2.
- `acp.run` loads the config with `settings.load_config_from_file`. ACP mode
  does not run the first-run setup, because the setup needs a terminal. If the
  config file is missing, Mimir uses the default Ollama config, as the
  terminal UI does before setup, and logs this to stderr. If the config file
  is invalid, Mimir writes the error to stderr and exits with status 1 before
  it reads stdin. The client then shows that the agent exited, with the stderr
  text.
- CI tests packages from a fixed list in `.github/workflows/ci.yml`. The `acp`
  package (and `session`, from #48) must be added to it.

### Transport and logging

ACP's stdio transport (Transports page): each message is one JSON-RPC 2.0
object on one line, delimited by `\n`, UTF-8, with no embedded newlines. The
Agent "MUST NOT write anything to its `stdout` that is not a valid ACP
message" and "MAY write UTF-8 strings to its standard error (`stderr`) for
logging purposes".

- **Only the protocol writer writes to stdout.** At startup, `acp.run` keeps
  the original `os.stdout` as its protocol stream and sets `os.stdout` to
  `os.stderr`. `fmt.print*` reads `os.stdout` on every call, so a stray print
  anywhere in the process goes to stderr instead of corrupting the protocol
  stream. This is done before any thread starts.
- The two existing stdout prints in `builtin_tools/builtin.odin`
  (`File already exists...` and the `/etc/shells` read error) move to the tool
  result or to stderr as part of #49. The redirect is a safety net, not a
  reason to keep them.
- `context.logger` is a stderr logger. `Notice` events, ignored messages,
  stale permission responses and protocol errors are logged there.
- Outbound messages are marshaled with `core:encoding/json` (which escapes
  newlines in strings), followed by one `\n`, and written with a loop until
  every byte is written. Only the main thread writes.
- Inbound lines may end in `\r\n` on Windows. The reader strips a trailing
  `\r`.
- Tool subprocesses do not inherit stdin. `os.process_exec` gives the child
  `/dev/null` (or `NUL` on Windows) when `desc.stdin` is `nil`, which is what
  `run_in_terminal` does today. This must stay true: a child that reads the
  inherited stdin would consume ACP messages.

### Main loop and stdin

One reader thread and the main thread:

- **Reader thread.** Blocks in `os.read` on stdin, splits the bytes on `\n`
  and pushes each complete line (owned copy) into a queue guarded by a
  `sync.Mutex`, then posts a `sync.Sema`. On EOF or a read error it sets an
  EOF flag and posts the semaphore. A line longer than
  `ACP_MAX_MESSAGE_BYTES` (16 MiB) is dropped: the reader skips to the next
  `\n` and queues a marker, and the main thread answers it with a `-32700`
  parse error with `id: null`.
- **Main thread.** Each iteration:
  1. Drain the inbound queue and handle each message (requests,
     notifications and responses to Mimir's own requests).
  2. For every session in the map: `session_poll`, then drain
     `session_next_event` until it returns false, and turn each event into
     zero or more outbound messages.
  3. Flush coalesced subagent content (see Subagents) and approval holds
     whose timer has run out (see Approvals).
  4. Write the outbox to stdout.
  5. Wait on the semaphore with `sync.sema_wait_with_timeout`: 10 ms while
     any session has an active turn or a held approval, 100 ms otherwise. A
     new stdin line wakes the loop at once.

The reader thread exists because a non-blocking stdin check does not work the
same way on both platforms. On Linux `poll` on the pipe would work
(`app_wait_for_input_other.odin` does that for the terminal). On Windows,
`app_wait_for_input_windows.odin` uses `WaitForSingleObject` on the stdin
handle, which works for a console handle, but an editor starts the agent with
an anonymous pipe as stdin, and pipe handles are not waitable objects. A
blocking read on a thread works on both and keeps partial-line handling out of
the main loop. Sessions do not signal the semaphore. They are polled, as
ADR-0002 requires ("events are pulled").

**Shutdown.** On stdin EOF, the main loop calls `session_cancel` on every
session with an active turn, keeps polling until every turn has ended or two
seconds have passed, calls `session_destroy` on every session, joins the
reader thread and returns exit status 0. Responses to open `session/prompt`
requests are still written; the client may have closed its end, so write
errors after EOF are ignored.

### Connection state

```odin
Connection :: struct {
	config:            ^settings.Mimir_Config,
	configHome:        string,
	initialized:       bool,
	client:            Client_Capabilities, // the subset Mimir reads
	sessions:          map[string]^ACP_Session, // ACP sessionId -> entry
	nextSessionNumber: int,
	nextRequestID:     i64, // IDs of Mimir's own requests to the client
	outbound:          map[i64]Outbound_Request, // open session/request_permission
	outbox:            [dynamic]string, // lines to write
}

ACP_Session :: struct {
	id:              string,
	session:         ^session.Session,
	promptID:        json.Value, // ID of the open session/prompt, or nil
	cancelRequested: bool,
	toolCalls:       map[string]Tool_Call_View, // open tool calls of the turn
	subagentStack:   [dynamic]string, // run_subagent tool call IDs
	approval:        Approval_Hold, // held or open permission request
}
```

The names are illustrative. The connection appends outbound lines to `outbox`
and `acp.run` writes them. Tests call the message handler and the tick
procedure directly and read `outbox`, so they need no pipes and no threads.
This is not a callback: nothing calls back into a session.

### `initialize`

Request params used: `protocolVersion` (required), `clientCapabilities`,
`clientInfo`. Mimir always answers `protocolVersion: 1`: if the client asks
for another version, the spec says the Agent "MUST respond with the latest
version it supports".

Response:

```json
{
  "protocolVersion": 1,
  "agentCapabilities": {
    "loadSession": false,
    "promptCapabilities": { "image": false, "audio": false, "embeddedContext": false },
    "mcpCapabilities": { "http": false, "sse": false },
    "sessionCapabilities": { "close": {} }
  },
  "agentInfo": { "name": "mimir", "title": "Mimir", "version": "<build version>" },
  "authMethods": []
}
```

Advertised in v1:

- **`sessionCapabilities.close`.** `session/close` cancels the turn (as
  `session/cancel` does), destroys the session and answers `{}`. Each session
  holds its own skill registry, code index and dispatcher, so a client must be
  able to free them. It is cheap given `session_cancel` and
  `session_destroy`.
- **Baseline prompt content.** Every Agent "MUST support `text` and
  `resource_link` content blocks". See `session/prompt`.

Left out in v1, with the reason:

- **`loadSession`, `sessionCapabilities.resume`, `list`, `delete`.** The
  session owns its transcript (ADR-0002), but nothing saves it. ADR-0002 keeps
  saved sessions out of scope.
- **`promptCapabilities.image` and `audio`.** The `ai` package sends text
  messages only.
- **`promptCapabilities.embeddedContext`.** `session_submit` takes one text
  string. Without this capability, clients send files as `resource_link`, and
  the model reads them with `read_file` under the normal permission checks.
  Inlining text resources is a small follow-up if users want it.
- **`mcpCapabilities.http` and `sse`.** Mimir has no MCP client.
- **`sessionCapabilities.additionalDirectories`.** A session has one project
  root, and the permission checks confine file tools to it.
- **`sessionCapabilities.systemPrompt`.** Mimir already has `systemPrompt` and
  `systemPromptMode` in the config. Per-session client prompts can follow.
- **`authMethods` and `agentCapabilities.auth`.** Provider credentials live in
  the Mimir config. A `terminal` auth method that runs the first-run setup in a
  client terminal is a possible follow-up.
- **Session modes and config options** (`session/set_mode`,
  `session/set_config_option`). ADR-0002 lets a front end change the model and
  approval method for one session. ACP config options are the natural surface
  for that, but they are not needed for v1.

Client capabilities Mimir reads:

- `session.notices`: when present, `Notice` events are also sent as `notice`
  updates (see Events).
- `subagents`: read and stored, not used in v1 (see Subagents).

Mimir never calls `fs/*` or `terminal/*`, so it ignores `fs.readTextFile`,
`fs.writeTextFile` and `terminal`. Tools keep reading and writing the disk
directly and running commands with `os.process_exec`. Routing them through the
client would make unsaved editor buffers visible to the model, but it would
put the client inside the tool worker, which runs on its own thread and is
synchronous. That is a separate decision.

**Before initialization.** Any request other than `initialize` gets `-32600`,
as the Errors page recommends. Notifications are ignored. A second
`initialize` also gets `-32600`.

### `session/new`

Params: `cwd` (required), `mcpServers` (required), `additionalDirectories`,
`systemPrompt`, `_meta`.

1. `cwd` must be an absolute path to an existing directory
   (`tool_policy.permission_path_is_absolute` handles Windows drive paths).
   Otherwise: `-32602`.
2. `additionalDirectories` that is present and not empty, or a non-null
   `systemPrompt`, gets `-32602`: the client "MUST only send" them when the
   Agent advertises them.
3. `mcpServers` that is not empty: Mimir does not connect to the servers. It
   logs their names to stderr and, if the client advertised `session.notices`,
   sends a `notice` with severity `warning` once the session exists. The
   session is still created. See Consequences: this does not meet a spec MUST.
4. Call `session_create(config, options)` with `projectRoot = cwd`, the
   process `configHome`, and the model and approval method from the config.
5. Generate the ACP session ID `sess_<n>`, where `n` counts up from 1 in the
   process. Without `session/load`, IDs only need to be unique on the
   connection, which the spec requires.
6. Respond `{ "sessionId": "sess_<n>" }`. No `modes`, no `configOptions`.

Two sessions with different `cwd` values are independent: each has its own
`^Session`, dispatcher, session grants, skill registry, code index and tool
worker (ADR-0002). They share only the config, so an `Allow_Always` grant from
one is visible to the other through `config.permissionGrants`.

### `session/prompt`

Params: `sessionId`, `prompt` (array of `ContentBlock`).

1. Unknown `sessionId`: `-32002` with `data.sessionId`.
2. Build one text string from `prompt`, in order:
   - `text`: the text.
   - `resource_link`: `@<uri>` on its own line, followed by ` (<name>)` when
     `name` differs from the last path segment. For `file://` URIs inside the
     project root, Mimir writes the path relative to the root, so the model can
     pass it to `read_file`.
   - Any other type (`image`, `audio`, `resource`): `-32602`. Mimir did not
     advertise them.
   - An empty result: `-32602`.
3. `session_submit(session, text)`. `.Busy` gets `-31001` (see Errors).
4. Store the request ID as the open `promptID`. Do not respond yet.

The response is sent when the session emits `Turn_Ended` (see Events), after
every update of the turn has been written. That ordering is required:
"the Agent MAY send `session/update` notifications ... after receiving the
`session/cancel` notification, but it MUST ensure that it does so before
responding to the `session/prompt` request."

### `session/cancel` and `$/cancel_request`

`session/cancel` is a notification with `sessionId`. Mimir sets
`cancelRequested` on the session and calls `session_cancel`. An unknown
session ID is logged and ignored (a notification has no response).

When the turn then ends, the response is `{ "stopReason": "cancelled" }`, also
when the session reports `Failed`. The spec says Agents "MUST catch these
errors and return the semantically meaningful `cancelled` stop reason". An
aborted HTTP request can surface as `Failed`.

The client "MUST respond to all pending `session/request_permission` requests
with the `cancelled` outcome" when it cancels. Mimir does not have to send
`$/cancel_request` for those. It ignores the late response if
`session_cancel` has already settled the approval.

Inbound `$/cancel_request` with `requestId`:

- If `requestId` is the open `session/prompt` of a session, Mimir handles it
  like `session/cancel` for that session. The Request Cancellation page
  accepts `stopReason: "cancelled"` as the response.
- All other Mimir responses are sent at once, so any other `requestId` is
  ignored.

### Events

ACP `session/update` notifications have the shape
`{ "sessionId": "...", "update": { "sessionUpdate": "<variant>", ... } }`.

| Session event | ACP output |
| --- | --- |
| `Message_Delta`, depth 0 | `agent_message_chunk` with `content: { type: "text", text }` |
| `Message_Delta`, depth > 0 | content of the `run_subagent` tool call (see Subagents) |
| `Thinking_Changed` | nothing |
| `Usage_Updated` | `usage_update` with `used` and `size` |
| `Tool_Call_Started` | `tool_call` |
| `Tool_Call_Updated` | `tool_call_update` |
| `Approval_Requested` | `session/request_permission` request (see Approvals) |
| `Approval_Safety_Updated` | releases a held request, or a `tool_call_update` |
| `Approval_Resolved` | nothing, or `$/cancel_request` if the request is open |
| `Subagent_Started` | `tool_call_update` of the `run_subagent` call |
| `Subagent_Finished` | `tool_call_update` of the `run_subagent` call |
| `Turn_Ended` | `session/prompt` response or error response |
| `Notice` | stderr log, plus `notice` if the client has `session.notices` |

Details:

- **`agent_message_chunk`.** `ContentChunk` has `content` (required) and an
  optional `messageId`. v1 omits `messageId`, because `Message_Delta` does not
  mark message boundaries.
- **`usage_update`.** `UsageUpdate` requires `used` and `size` (unsigned
  token counts, non-null) and allows `cost`. Mimir sends `used` and `size`
  from the event and no `cost`. If the context window size is unknown (0),
  Mimir sends nothing, because `size` cannot be null.
- **`tool_call`.** `ToolCall` requires `toolCallId` and `title`. Mimir sends:
  - `toolCallId`: the model's tool request ID (ADR-0002).
  - `title`: `<tool ID>: <target>`, or the tool ID alone when there is no
    target. The terminal's formatter is in package `main`, so `acp` has its
    own short formatter.
  - `name`: the tool ID, for example `read_file`.
  - `kind`: from the table below.
  - `status`: from the status map below. A call that waits for approval
    starts as `pending`.
  - `locations`: `[{ "path": <absolute target path> }]` for tools whose
    target is a path. Relative targets are joined to the session's project
    root.
  - `rawInput`: the raw arguments, parsed as JSON. If they do not parse, they
    are sent as a JSON string.
- **`tool_call_update`.** `ToolCallUpdate` requires only `toolCallId`. Mimir
  sends `status`, and `content` when there is output:
  - Output text: `{ "type": "content", "content": { "type": "text", "text" } }`.
  - A file diff: `{ "type": "diff", "path", "oldText", "newText" }`. `path`
    is absolute, `newText` is the whole new file, and `oldText` is the whole
    old file or `null` for a new file. ACP has no unified-diff content type
    (see Dependencies on #48).
  - `content` replaces the whole array on each update, so each update sends
    the full content of the call.
- **Status map** (ADR-0002, checked against `ToolCallStatus`, which has
  exactly `pending`, `in_progress`, `completed` and `failed`):

  | `Tool_Call_Status` | ACP `status` |
  | --- | --- |
  | `Awaiting_Approval` | `pending` |
  | `Running` | `in_progress` |
  | `Completed` | `completed` |
  | `Failed` | `failed` |
  | `Denied` | `failed`, with content text `Permission denied.` |

- **Tool kinds** (`ToolKind`):

  | Tool ID | `kind` |
  | --- | --- |
  | `read_file`, `read_skill`, `list_directory`, `get_file_info` | `read` |
  | `write_file`, `replace_string_in_file`, `patch_file` | `edit` |
  | `run_in_terminal` | `execute` |
  | `grep_search`, `search_code`, `find_code` | `search` |
  | `list_available_shells`, `run_subagent`, any other | `other` |

- **Open tool calls at the end of a turn.** ACP has no `cancelled` tool
  status. The client "SHOULD preemptively mark all non-finished tool calls ...
  as `cancelled`". So that the record is still complete, Mimir sends
  `status: "failed"` for every tool call of the turn that has no final status
  when `Turn_Ended` arrives, before the prompt response.
- **`Turn_Ended`.**

  | Reason | Response to `session/prompt` |
  | --- | --- |
  | `Completed` | `{ "stopReason": "end_turn" }` |
  | `Canceled` | `{ "stopReason": "cancelled" }` |
  | `Failed`, after `session/cancel` | `{ "stopReason": "cancelled" }` |
  | `Failed` | error `-32603`, `message` = error text, `data.sessionId` |
  | `Limit_Reached` (future) | `{ "stopReason": "max_turn_requests" }` |

  `StopReason` in the schema is exactly `end_turn`, `max_tokens`,
  `max_turn_requests`, `refusal` and `cancelled`. Mimir does not report
  `max_tokens` or `refusal` in v1, because the session has no matching turn
  end reason.
- **`Notice`.** Always logged to stderr with its severity. If the client
  advertised `session.notices`, Mimir also sends
  `{ "sessionUpdate": "notice", "severity": "info" | "warning" | "error",
  "title": <text> }`. ADR-0002 says "stderr log for now". The `notice` update
  is gated by a client capability, so this adds to the ADR mapping without
  changing it for other clients. The spec says a notice "MUST NOT carry
  information required for protocol correctness", which holds for `Notice`.

### Approvals

`session/request_permission` is a request from Mimir to the client:

```json
{
  "sessionId": "sess_1",
  "toolCall": { "toolCallId": "<tool request ID>", "title": "...", "kind": "...",
                "content": [ ... ], "locations": [ ... ] },
  "options": [ { "optionId": "...", "name": "...", "kind": "..." } ]
}
```

`toolCall` is a `ToolCallUpdate`. Mimir repeats the title, kind, locations and
raw input, and adds a text content block with the safety verdict and reason
when one is known. The ACP Security section says Clients "SHOULD describe the
operation from the tool call's `kind`, `locations`, and content", so the
command or path goes there in full.

**Options.** `PermissionOptionKind` has exactly `allow_once`, `allow_always`,
`reject_once` and `reject_always`. It has no session-scoped kind. The spec
says: "The Agent owns remembered decisions. When the user selects an
`allow_always` or `reject_always` option, the Agent stores the decision,
decides its scope ... and how long it lasts", and "the option `name`
describes the scope". So both remembered grants use `allow_always`, and the
name tells them apart:

| `optionId` | `kind` | `name` | `Approval_Choice` |
| --- | --- | --- | --- |
| `allow-once` | `allow_once` | `Allow once` | `Allow_Once` |
| `allow-session` | `allow_always` | `Allow for this session: <scope>` | `Allow_Session` |
| `allow-always` | `allow_always` | `Always allow: <scope>` | `Allow_Always` |
| `reject-once` | `reject_once` | `Deny` | `Deny` |

- `<scope>` comes from `tool_policy.tool_dispatch_grant_from_action` on the
  event's permission action: `writes in <directory>` for a
  `Directory_Subtree` grant, and `commands starting with <command>` for a
  `Command_Prefix` grant. The spec says Agents "SHOULD state the scope of a
  remembered decision ... in the option `name`".
- When no grant can be made from the action (reads, commands outside the
  project root, writes with no parent directory), Mimir sends only
  `allow-once` and `reject-once`. Otherwise `session_resolve_approval` would
  refuse the choice, as the terminal does today ("Tool call requires one-time
  approval").
- Mimir has no deny grants, so it never offers `reject_always`.

**Response handling.** `RequestPermissionResponse.outcome` is either
`{ "outcome": "selected", "optionId" }` or `{ "outcome": "cancelled" }`.

- A known `optionId`: call `session_resolve_approval` with the choice from the
  table.
- An unknown `optionId`, or an outcome Mimir does not know: `Deny`. The spec
  says Agents "SHOULD NOT treat an outcome they don't recognize as approval".
- `cancelled`: if `session/cancel` came first, do nothing, because
  `session_cancel` settles the approval. Otherwise `Deny`.
- A JSON-RPC error response (for example `-32800` after Mimir's
  `$/cancel_request`): `Deny` if the approval is still pending, else ignore.
- The approval was already resolved (`Approval_Resolved` came first): ignore
  the response and log it.
- `session_resolve_approval` reports that the grant was not saved (for
  example the config file cannot be written): the approval stays pending.
  Mimir logs the error and sends a new `session/request_permission` with only
  `allow-once` and `reject-once`.

**Holding the request under `Approve_Safe`.** ADR-0002 (Consequences) says the
front end "should wait for `Approval_Safety_Updated` before it sends
`session/request_permission`", so the client does not show a prompt that the
session then approves by itself. Mimir refines this:

- Under `Approve_Safe`, when `Approval_Requested` arrives and its verdict is
  still pending, Mimir holds the request. The tool call is already visible as
  `pending`.
- `Approval_Resolved` while held: drop the hold. Nothing was sent.
- `Approval_Safety_Updated` while held: send the request, with the verdict in
  the tool call content.
- When the safety model is unavailable, the current code marks the safety
  state unavailable at once, so no `Approval_Safety_Updated` will follow. If
  `Approval_Requested` already says unavailable (or has a final verdict),
  Mimir sends the request at once.
- Hold timeout: `ACP_SAFETY_HOLD_TIMEOUT_MS` = 15 000. After it, Mimir sends
  the request anyway. A classifier request is only bounded by
  `stallTimeoutSeconds` (300 by default), which is too long to show nothing.
  If the session approves the call after that, Mimir sends
  `$/cancel_request` (below). This is a constant, not a config key.
- Under `Always_Ask`, Mimir sends the request at once. Shell commands start
  the classifier as advice. When `Approval_Safety_Updated` arrives while the
  request is open, Mimir sends a `tool_call_update` with the verdict as
  content. It cannot change an open request.
- `Approve_All` and `Deny_All` emit no `Approval_Requested` (ADR-0002), so
  nothing is sent to the client.

**`$/cancel_request`.** Name and shape from `meta.json`
(`protocolMethods.cancel_request`) and `CancelRequestNotification`:
`{ "requestId": <id> }`. When `Approval_Resolved` arrives while a permission
request is open, Mimir sends it with that request's JSON-RPC ID and keeps the
request in `outbound` until the response comes. Support is optional for the
client ("Cancellation remains optional"), so the late response is handled by
the rules above and never applied to a later approval: responses are matched
by JSON-RPC ID, and the stored tool call ID must still be the pending one.

### Subagents

ADR-0002 maps subagent events to the `run_subagent` tool call. ACP v1 allows
this: "An Agent can use subagents without exposing them and report their
results through the parent session." v1 does that:

- `Subagent_Started`: push the parent tool call ID on `subagentStack`. Send a
  `tool_call_update` for it with `status: "in_progress"` and a text content
  block with the task.
- `Message_Delta` with depth `d > 0`: append the text to the content buffer of
  `subagentStack[d - 1]`. Because `content` replaces the whole array, Mimir
  sends at most one `tool_call_update` per main-loop iteration for each call
  with new text, not one per delta.
- Tool calls that the subagent makes arrive as ordinary `Tool_Call_Started`
  and `Tool_Call_Updated` events and are sent as tool calls of the ACP
  session. Their permission requests also use the ACP session ID.
- `Subagent_Finished`: flush the buffer, send a `tool_call_update` whose
  content ends with the result text, and pop the stack. The final status comes
  from the `Tool_Call_Updated` event for the `run_subagent` call.

ACP schema 1.34.0 (2026-11-20) made child sessions stable: `subagent_update`,
`session_message` and `session_message_chunk`, and `session` tool call
content, all gated by the client's `subagents` capability. Exposing each Mimir
subagent as a child session is a better fit for clients that support it, and
it is a follow-up. It needs a child session ID per subagent and routes the
child's tool calls and permission requests to that ID.

### Errors

ACP error codes (Errors page and `ErrorCode` in the schema): `-32700` parse
error, `-32600` invalid request, `-32601` method not found, `-32602` invalid
params, `-32603` internal error, `-32800` request cancelled, `-32000`
authentication required, `-32002` resource not found. The spec says
implementation-specific errors "SHOULD use codes outside `-32768` to `-32000`
and `-32899` to `-32800`". Mimir's own codes use `-31000` to `-31099`.

| Case | Code |
| --- | --- |
| Line is not valid JSON, or longer than the limit | `-32700`, `id: null` |
| Not a JSON-RPC 2.0 object, a batch (array), or a request before `initialize` | `-32600` |
| Unknown method, or a method whose capability Mimir did not advertise | `-32601` |
| Missing or wrong-typed params, bad `cwd`, unsupported content or fields | `-32602` |
| Unknown `sessionId` on `session/prompt` | `-32002`, `data.sessionId` |
| `session_submit` returns `.Busy` | `-31001` "Session has an active turn" |
| `session_create` fails because no usable provider or model is configured | `-31002` |
| `session_create` fails for another reason | `-32603` |
| `Turn_Ended` with `Failed` (not after a cancel) | `-32603`, `data.sessionId` |

- Methods answered with `-32601` in v1: `authenticate`, `logout`,
  `session/load`, `session/resume`, `session/list`, `session/delete`,
  `session/set_mode`, `session/set_config_option`, and every `_`-prefixed
  extension method.
- Unknown notifications, including `_`-prefixed ones, are logged and ignored.
- `session/close` for an unknown session answers `{}` (closing is
  idempotent).
- `session_cancel` errors are logged only, because `session/cancel` is a
  notification.
- `session_resolve_approval` errors for a tool call that is no longer pending
  are logged and ignored. A stale response is expected after a cancel or an
  automatic approval.
- The `Session_Error` names above are provisional until #48 settles them.

### Command line and configuration

- New flag: `mimir --acp`. No other flags in v1.
- No new config keys. ACP sessions use the existing keys: the selected
  provider and model, `approvalMethod`, `safetyProvider` and `safetyModel`,
  `toolContinuations`, the subagent limits, the timeouts, `systemPrompt` and
  `systemPromptMode`, `disabledSkills` and `permissionGrants`.
- `docs/configuration.md` gets a short ACP section: these keys apply to ACP
  sessions, `approvalMethod` is applied by the session before the client is
  asked, an `Always allow` choice in the client writes `permissionGrants` to
  the config file, and the config is read once at startup.
- `docs/acp.md` (new, user-facing) explains how to register `mimir --acp` as
  an agent in an editor, what is supported, and where logs go.
- `README.md` lists the flag.

### Tests

`acp/acp_test.odin` drives a `Connection` with JSON-RPC lines and checks the
`outbox`, with sessions backed by the fake provider that #48's session tests
use. They cover at least:

- `initialize`: version and capabilities; a request before it gets `-32600`.
- `session/new` with a relative or missing `cwd` gets `-32602`.
- Two sessions with different `cwd` values: prompts, tool calls and session
  grants stay in their own session (#49 acceptance criterion).
- Prompt text streams as `agent_message_chunk`, and the response is
  `end_turn` after the last update.
- `.Busy` on a second prompt.
- `session/cancel` during a turn gives `cancelled`, also when the session
  reports `Failed`.
- Permission round trips for each option, including `allow-session` (a second
  matching call in the same session needs no request) and `allow-always` (the
  grant is in `config.permissionGrants` and is saved to a temporary config
  home) (#49 acceptance criterion).
- `Approve_Safe`: the request is held until `Approval_Safety_Updated`; an
  automatic approval sends no request; an approval after the request is open
  sends `$/cancel_request` and the late response is ignored.
- Unknown option ID or outcome resolves as `Deny`.
- Unknown session gets `-32002`; unknown method gets `-32601`; invalid JSON
  gets `-32700`.
- Stdin EOF with an active turn: the prompt is answered and the run returns.

## Dependencies on #48

The front end needs these details from the `session` package. Each is
compatible with ADR-0002, but #48 has not fixed them yet:

1. **Safety verdict in `Approval_Requested`.** The event must tell "pending"
   from "unavailable" and from a final verdict, so the front end knows whether
   an `Approval_Safety_Updated` will follow. The verdict reason text, when
   there is one, is shown to the user.
2. **Permission action in `Approval_Requested`.** It must carry the
   `tool_policy.Permission_Action` (effect, target path, command, working
   directory), so the front end can build the grant scope text and decide
   which options to offer.
3. **`session_resolve_approval` result.** It must tell "resolved" from "no
   longer pending / unknown tool call" (stale, ignore) and from "grant not
   saved, still pending" (ask again). Today's `Approval_Resolve_Result` has
   these cases; the `Session_Error` returned by the ADR's signature must keep
   them apart.
4. **`session_cancel` with a pending approval.** It must settle the approval
   (and emit `Approval_Resolved` or a `Denied` `Tool_Call_Updated`) and end the
   turn with `Canceled`, so the front end does not resolve it again.
5. **Event order.** `Tool_Call_Started` comes before `Approval_Requested` for
   the same call. If it does not, the front end sends a `tool_call` first.
6. **File diff in `Tool_Call_Updated`.** ACP's `diff` content needs an
   absolute path and the whole old and new file text. A unified-diff string
   can only be sent as a text block.
7. **Subagent attribution.** `Message_Delta` carries depth only. The front end
   maps depth to the innermost `run_subagent` call through
   `Subagent_Started` and `Subagent_Finished`. A parent tool call ID on
   `Message_Delta` would remove that inference.
8. **`Usage_Updated` values.** "Used tokens" should be the current context
   usage (input tokens of the latest request), which is what `usage_update`'s
   `used` means. A context window size of 0 means unknown.
9. **`session_create` errors.** A distinct error for "no usable provider or
   model" so it can map to `-31002` with a useful message.
10. **`session_destroy` during a turn.** For `session/close` and shutdown the
    front end cancels first and waits for `Turn_Ended`. If #48 makes
    `session_destroy` safe with a running tool worker, the wait can be
    shorter.
11. **Test provider.** The ACP tests need the same fake provider hook as the
    session tests.

## Differences from ADR-0002

The ACP names in ADR-0002 match the v1 schema: `agent_message_chunk`,
`tool_call`, `tool_call_update`, `usage_update`,
`session/request_permission`, `$/cancel_request` (a protocol-level
notification in `meta.json`) and the stop reason `max_turn_requests` all
exist with those exact names, and the status map (`Awaiting_Approval` →
`pending`, `Denied` → `failed`) fits `ToolCallStatus`. No contradictions were
found. This document refines the ADR in four places:

- **Approve_Safe wait.** The ADR says to wait for `Approval_Safety_Updated`.
  When the safety model is unavailable, that event never comes, so the wait
  applies only while the verdict is pending, and it has a 15 second limit.
- **Cancel stop reason.** The ADR maps `Turn_Ended` `Failed` to an error
  response. After `session/cancel`, ACP requires `cancelled`, so a `Failed`
  turn end after a cancel maps to `cancelled`.
- **`Notice`.** The ADR says "stderr log for now". The `notice` session update
  is now in the v1 schema, gated by `clientCapabilities.session.notices`.
  Mimir sends it when the client advertises it and always logs to stderr.
- **Subagents.** The ADR's mapping (content of the `run_subagent` tool call)
  is allowed by ACP and is used in v1. ACP now also has stable child sessions;
  using them is a follow-up.

## Alternatives considered

- **Non-blocking stdin on the main thread** (`poll` on Linux,
  `PeekNamedPipe` on Windows). No thread, but two code paths, and
  `PeekNamedPipe` fails for a console or file stdin, so tests and manual runs
  would need a third path. Rejected in favor of one reader thread.
- **Map `Allow_Session` to `allow_once`.** The client would show it as a
  one-time choice while Mimir remembers it. That contradicts the option kind.
  Rejected.
- **Offer only `allow_once` and `reject_once`.** Simple, but #49 requires
  session and persistent grants to round-trip through the client. Rejected.
- **Use the client's `fs/*` and `terminal/*` methods for tools.** Editors would
  see unsaved buffers and run commands in their own terminals, but the tool
  worker would wait on the client, and the permission checks would have to
  cover a second I/O path. Deferred to its own decision.
- **Reject `session/new` when `mcpServers` is not empty.** It follows the
  spec more strictly, but editors that pass their configured MCP servers would
  not work with Mimir at all. Rejected for v1.
- **Child sessions for subagents in v1.** Better UI in clients that support
  it, but it is more protocol surface, and the capability became stable one
  day before this document. Deferred.

## Consequences

- Mimir can run as a local ACP agent with several sessions in one process.
  Each session in a new directory loads its own skill registry and code
  index (ADR-0002).
- **Known spec gap: MCP servers.** The Session Setup page says "All Agents
  MUST support connecting to MCP servers via stdio". Mimir has no MCP client,
  so it accepts `mcpServers` and ignores it with a log line and an optional
  notice. Adding an MCP client is a separate decision.
- Stdout is reserved for the protocol. Any new code that prints must use
  stderr or the logger. The `os.stdout` redirect hides mistakes from the
  protocol stream, but they still show up in stderr.
- Tool subprocesses must keep getting a null stdin.
- Approval behavior is the same as in the terminal, because the approval
  method runs in the session. The client only answers the cases the terminal
  would show in its overlay.
- An `Always allow` from the client changes the shared config file. A
  terminal Mimir that is already running does not see the new grant until it
  reloads the config, as today.
- The `acp` package and its tests must be added to the CI package list.

## Resolved questions

These were open when the ADR was proposed. Each was settled in favor of this
proposal when the ADR was accepted:

- **MCP servers:** a non-empty `mcpServers` is accepted, ignored and logged as a
  warning. It is not rejected with `-32602`.
- **Safety hold timeout:** 15 seconds, as a constant. It is not a config key.
- **Embedded context:** v1 does not advertise
  `promptCapabilities.embeddedContext`. Prompts support `text` and
  `resource_link` only.
- **Per-session model and approval method:** not exposed as ACP session config
  options in v1. They come later.
- **Error codes:** Mimir-specific codes in `-31000` to `-31099` are used;
  `.Busy` maps to `-31001`.
