# Configuration

Mimir stores its main configuration file here:

```text
$HOME/.config/mimir/config.json
```

Mimir stores submitted input history here:

```text
$HOME/.cache/mimir/history-<working-directory-hash>.json
```

Each history file belongs to one absolute working directory. `/clear` removes
only the history file for the current directory.

Mimir stores semantic code indexes here:

```text
$HOME/.cache/mimir/code-index-<project-and-model-hash>.vdb
```

Mimir uses the Git project root for the cache when it finds one. Otherwise, it
uses the working directory. The cache also identifies the embedding provider and
model. Projects and embedding models do not share vectors. Mimir loads a
matching cache at startup. It builds the cache when `search_code` first uses it.

## First Run

At startup, Mimir probes the default native Ollama endpoint:

```text
http://localhost:11434
```

If Ollama is available, Mimir saves a default provider configuration. Otherwise,
Mimir asks for an endpoint URL and an optional API key. It saves the
configuration after it connects successfully.

At startup, Mimir updates model lists for configured Ollama providers. Select a
model with `/config`. If the configuration is invalid, Mimir starts setup mode
and keeps the existing file.

## Configuration Format

The initial configuration shape is:

```json
{
  "selectedProvider": "ollama",
  "selectedModel": "",
  "embeddingProvider": "",
  "embeddingModel": "",
  "safetyProvider": "",
  "safetyModel": "",
  "approvalMethod": "alwaysAsk",
  "toolContinuations": 1000,
  "maxSubagentDepth": 2,
  "maxSubagentsPerSession": 10,
  "systemPrompt": "",
  "systemPromptMode": "append",
  "contextWindows": [
    {
      "providerName": "ollama",
      "model": "qwen3.5",
      "tokens": 262144
    }
  ],
  "providers": [
    {
      "name": "ollama",
      "type": "ollama",
      "endpoint": "http://localhost:11434",
      "apiKey": "",
      "model": "",
      "enabled": true
    }
  ],
  "mcpServers": [],
  "skillPaths": [],
  "permissionGrants": []
}
```

`selectedProvider` and `selectedModel` set the chat model.
`embeddingProvider` and `embeddingModel` set the model for semantic code search.
They are separate from the chat model. Before you use `search_code`, select an
embedding provider and model in `Embedding Model`. Mimir does not select a
default embedding model.

`safetyProvider` and `safetyModel` set the model that classifies tool actions in
the approval dialog. Select a chat provider and model in `Safety Model` to use
a separate safety model. If both values are empty, Mimir uses the chat provider
and model. An incomplete or invalid safety selection disables safety advice.

`mcpServers` configures MCP (Model Context Protocol) servers. Each entry has:

- `name`: identifies the server. Tool, resource, and prompt names from this
  server are exposed to the model as `{name}.{toolName}`.
- `command` and `args`: spawns the server as a subprocess and speaks
  newline-delimited JSON-RPC over its stdin/stdout.
- `url`: connects to the server over Streamable HTTP instead. Set either
  `command` or `url`, not both.
- `enabled`: set to `false` to keep the entry in the config without
  connecting to it.

See [tools-mcp-skills.md](tools-mcp-skills.md) for the supported protocol
revision, transports, and approval model.

`approvalMethod` controls actions that require approval after Mimir checks the
normal permission grants. It defaults to `alwaysAsk` when omitted. Set it in
`/config` under `Advanced`, or use one of these JSON values:

- `alwaysAsk`: show the approval dialog. Shell commands show safety advice when
  a safety model is available.
- `approveSafe`: classify writes, shell commands, and remote/MCP calls. Mimir
  allows only an exact `SAFE|reason` response. An unavailable safety model,
  malformed response, `RISKY`, or `UNCLEAR` response opens the approval dialog.
- `approveAll`: allow every action that would otherwise require approval. Mimir
  does not call the safety model.
- `denyAll`: deny every action that would otherwise require approval.

Read-only project access and matching session or persistent permission grants
are resolved before `approvalMethod`; this setting does not create or change
permission grants.

`toolContinuations` sets the maximum number of consecutive model and tool
continuation cycles for one request. It must be a positive integer and defaults
to `1000`. Change it through `/config` in `Advanced`, or edit the JSON file.

`maxSubagentDepth` sets how many levels of subagents the `create_subagent`
tool may spawn. A top-level agent that calls `create_subagent` starts its
child with this many levels of budget remaining; each further nested subagent
must request a `depth` at or below its own remaining budget minus one. It must
be a non-negative integer and defaults to `2`. Set it to `0` to disable
subagent spawning.

`maxSubagentsPerSession` caps the total number of subagents `create_subagent`
may spawn for one session, across all nesting levels. It must be a
non-negative integer and defaults to `10`.

`systemPrompt` adds instructions for the chat model. Mimir always has an
original default coding-agent prompt. `systemPromptMode` controls how custom
text is used:

- `append` (the default) sends Mimir's default prompt followed by the custom
  prompt. Use this to add project, style, or workflow instructions while
  retaining Mimir's normal coding-agent behavior.
- `replace` sends only `systemPrompt`. An empty value intentionally sends no
  configured system instruction.

Set both values in `/config` under `Advanced`. The system-prompt editor accepts
multiple lines. Press Enter for a new line, Ctrl-S to save, or Esc to discard
the edit. **Reset system prompt** clears the custom prompt and restores
`append` mode. Configurations created before these fields existed behave as an
empty custom prompt in `append` mode.

`contextWindows` can store a manual context limit for a provider and model. The
value must not be negative. A value of `0` means the limit is unknown. For
Ollama, Mimir reads a positive `model_info` key that ends in `.context_length`
from `/api/show`. This value takes priority over the manual limit. **Refresh
models** finds these values for all listed Ollama models and saves changed
positive values. Missing or unsupported metadata keeps an existing limit and
does not stop chat.

## Permission Grants

Built-in file operations are confined to Mimir's active project directory.
Mimir allows reads inside the project directory by default. Writes and commands
need approval unless a matching grant exists. Mimir stores grants in the user
configuration. Each grant applies to one canonical project path.

`permissionGrants` accepts the following grant kinds:

```json
{
  "permissionGrants": [
    {
      "kind": "directorySubtree",
      "projectRoot": "/home/user/project",
      "directory": "/home/user/project/generated"
    },
    {
      "kind": "commandPrefix",
      "projectRoot": "/home/user/project",
      "command": "odin test"
    },
    {
      "kind": "mcpServer",
      "projectRoot": "/home/user/project",
      "mcpServer": "github"
    }
  ]
}
```

A `directorySubtree` grant applies only to writes in that directory. A
`commandPrefix` grant applies only when the command runs from the project root
and starts with the configured command. An `mcpServer` grant reserves trust for
a future MCP server connection.

Mimir rejects malformed grants, paths outside the project root, and path
traversal when it loads the configuration.

## Diagnostics

Raw LLM HTTP response output from the latest chat request is written to:

```text
$HOME/.cache/mimir/last_session.log
```

Mimir replaces the log when a new chat request starts. It adds response bodies
or stream chunks as they arrive. The log can contain model output and provider
error bodies. Treat it as local diagnostic data.
