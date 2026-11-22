# Using Mimir From an Editor (ACP)

Mimir can run as a local agent for editors and other clients that speak the
[Agent Client Protocol](https://agentclientprotocol.com/) (ACP), version 1:

```sh
mimir --acp
```

In this mode Mimir has no terminal UI. The client starts the process and talks
to it over stdin and stdout. One process can run several sessions, each in its
own project directory. The design is in
[ADR 0003](adr/0003-acp-front-end.md).

## Before You Start

ACP mode uses the same config file as the terminal UI
(`$HOME/.config/mimir/config.json`) and reads it once, at startup. It does not
run the first-run setup, because the setup needs a terminal. Run `mimir` in a
terminal once to set up a provider and select a model, or write the config
file yourself (see [Configuration](configuration.md)).

- If the config file is missing, Mimir uses the default Ollama config
  (`http://localhost:11434`) and writes a note to stderr.
- If the config file is invalid, Mimir writes the error to stderr and exits
  with status 1. The client shows that the agent exited.
- If no provider is enabled or no model is selected, `session/new` fails with
  error `-31002`.

## Register Mimir in an Editor

Register the Mimir executable as a custom ACP agent with the argument `--acp`.
The setting names differ between editors and can change; see the ACP
documentation of your editor. For example, in Zed's `settings.json`:

```json
{
  "agent_servers": {
    "Mimir": {
      "type": "custom",
      "command": "/path/to/mimir",
      "args": ["--acp"],
      "env": {}
    }
  }
}
```

Use the absolute path of the `mimir` binary (`mimir.exe` on Windows). The
editor sends the project directory as the session `cwd`. Mimir uses it as the
project root: file tools are confined to it, and commands run in it.

## What Is Supported

| Feature | Support |
| --- | --- |
| `initialize`, `session/new`, `session/prompt`, `session/cancel` | Yes |
| `session/close` (`sessionCapabilities.close`) | Yes. It cancels an active turn and frees the session. |
| `$/cancel_request` | Yes, for an open `session/prompt`. Mimir also sends it when it settles a permission request by itself. |
| Several sessions in one process | Yes. Each has its own project root, session grants, skills, code index and tool worker. |
| Prompt content | `text` and `resource_link`. A `file://` link inside the project root is given to the model as a path relative to the root, so it can read it with `read_file`. |
| Streamed reply | `agent_message_chunk` |
| Tool calls | `tool_call` and `tool_call_update`, with `kind`, `locations`, `rawInput`, the tool output as text, and `diff` content for `write_file`, `patch_file` and `replace_string_in_file` |
| Permission requests | `session/request_permission` (see below) |
| Subagents | Shown as content of the `run_subagent` tool call: the task, the subagent's text and its result |
| Context usage | `usage_update`, when the context window size of the model is known (`contextWindows` in the config) |
| Notices | `notice` updates, when the client advertises `session.notices`. Notices are always written to stderr. |

Not supported in this version: `session/load`, `session/resume`,
`session/list`, `session/delete`, session modes and config options
(`session/set_mode`, `session/set_config_option`), authentication methods,
images, audio and embedded resources in prompts, `additionalDirectories`, a
client `systemPrompt`, child sessions for subagents, and the client's `fs/*`
and `terminal/*` methods (tools read and write the disk and run commands
directly). These methods return `-32601`, and the unsupported fields return
`-32602`.

**MCP servers are not supported.** Mimir has no MCP client. It accepts the
`mcpServers` of `session/new`, ignores them, and writes their names to stderr
(and sends a warning `notice` when the client supports notices).

## Permission Requests

Tool calls go through the same permission checks as in the terminal.
`approvalMethod` from the config is applied first:

- `approveAll` and `denyAll` settle every call without asking the client.
- `alwaysAsk` asks the client for every call that needs approval. For shell
  commands, the safety verdict arrives later as content of the tool call.
- `approveSafe` waits for the safety verdict before it asks the client. A
  `SAFE` verdict runs the call without asking. Other verdicts, or no safety
  model, ask the client with the verdict in the tool call content. If the
  verdict takes longer than 15 seconds, Mimir asks anyway, and withdraws the
  request with `$/cancel_request` if a safe verdict arrives later.

The client sees these options:

| Option | Meaning |
| --- | --- |
| Allow once | Run this call. |
| Allow for this session: *scope* | Run this call, and allow matching calls in this session. |
| Always allow: *scope* | Run this call, and save a permission grant to the config file. |
| Deny | Do not run this call. The model is told that permission was denied. |

The scope is `writes in <directory>` or `commands starting with <command>`.
Calls that cannot be granted (reads outside the project, commands outside the
project root) offer only *Allow once* and *Deny*. An unknown answer counts as
*Deny*. An *Always allow* grant is visible to every session of the process at
once; a terminal Mimir that is already running sees it after it reloads its
config.

## Errors

| Code | Meaning |
| --- | --- |
| `-32700` | A line is not valid JSON, or is longer than 16 MiB. |
| `-32600` | Not a JSON-RPC 2.0 request, a batch, or a request before `initialize`. |
| `-32601` | A method that Mimir does not support. |
| `-32602` | Missing or invalid params, a bad `cwd`, or unsupported content or fields. |
| `-32002` | Unknown `sessionId` (`data.sessionId` names it). |
| `-32603` | The turn failed (for example a provider error), or a session could not be created. |
| `-31001` | The session already has an active turn. |
| `-31002` | No usable provider or model is configured. |

After `session/cancel`, the prompt always ends with the stop reason
`cancelled`, also when the provider request fails because it was aborted.

## Logs

Stdout carries only ACP messages. Mimir writes its log (sessions it created,
notices, ignored messages and protocol errors) to stderr; most editors show it
in their agent log. As in the terminal UI, the raw provider response of the
latest chat request is written to `$HOME/.cache/mimir/last_session.log` (see
[Diagnostics](configuration.md#diagnostics)); with several sessions, it holds
the latest request of any session.
