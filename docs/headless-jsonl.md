# Headless JSONL Test Harness

Mimir can run without the terminal UI for internal tests and local automation:

```sh
mimir --headless-json
```

In this mode, stdin receives newline-delimited JSON requests and stdout emits only
newline-delimited JSON responses. Human-readable diagnostics must go to stderr so
test harnesses can parse every stdout line as JSON.

This protocol is internal and may change with the tests that use it.

## Request Envelope

Each request is a JSON object with an `action` string. `id` is optional. When an
`id` is present, the response echoes it.

```json
{ "id": "1", "action": "get_history" }
```

Malformed JSON, missing actions, unknown actions, and invalid action parameters
return an error response and keep the process running.

```json
{
  "type": "error",
  "ok": false,
  "code": "unknown_action",
  "message": "unknown action"
}
```

## Actions

### `run_in_terminal`

Runs a slash command through the same command dispatcher used by the terminal UI.

```json
{ "id": "1", "action": "run_in_terminal", "command": "/config" }
```

### `send_message`

Submits chat text through the normal input submission path.

```json
{ "id": "2", "action": "send_message", "text": "hello" }
```

### `get_history`

Returns raw history entries. It does not return terminal-rendered or wrapped text.

```json
{ "id": "3", "action": "get_history" }
```

### `get_config`

Returns either a scalar config path or the current scalar config snapshot.

```json
{"id":"4","action":"get_config","path":"approvalMethod"}
{"id":"5","action":"get_config"}
```

Supported scalar paths are:

- `selectedProvider`
- `selectedModel`
- `embeddingProvider`
- `embeddingModel`
- `safetyProvider`
- `safetyModel`
- `approvalMethod`
- `toolContinuations`
- `maxSubagentDepth`
- `maxSubagentsPerSession`
- `systemPromptMode`

### `set_config`

Mutates a supported scalar config path. Writes are in memory by default. Use
`persist: true` only when the harness was started with an explicit config home
and the test expects a disk write.

```json
{
  "id": "6",
  "action": "set_config",
  "path": "approvalMethod",
  "value": "denyAll"
}
```

### `key` / `input_event`

Sends one low-level input byte through the existing app input handler. This is for
UI-parity tests that need to exercise terminal-style navigation without rendering.

```json
{ "id": "7", "action": "key", "byte": 13 }
```

### `approve` / `deny`

Resolves the current pending approval. `approve` defaults to `once`; it also
accepts `session` and `always`.

```json
{"id":"8","action":"approve","scope":"once"}
{"id":"9","action":"deny"}
```

### `wait_until_idle`

Polls app work until the agent stream and tool execution are idle, then returns a
status response.

```json
{ "id": "10", "action": "wait_until_idle" }
```

### `shutdown`

Stops the headless process after acknowledging the request.

```json
{ "id": "11", "action": "shutdown" }
```

## Test Determinism

Headless mode does not fake AI providers, tools, or config by itself. Tests must
configure temp homes, fake providers, or injected state explicitly.
