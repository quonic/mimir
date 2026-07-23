# Configuration

Mimir stores its main configuration file at:

```text
$HOME/.config/mimir/config.json
```

Submitted input history is stored separately beneath:

```text
$HOME/.cache/mimir/history-<working-directory-hash>.json
```

Each cache file belongs to one absolute working directory. `/clear` removes
only the history file for the directory from which Mimir is running.

Semantic code indexes are stored separately beneath:

```text
$HOME/.cache/mimir/code-index-<project-and-model-hash>.vdb
```

The index cache is scoped to the Git project root when one is found, otherwise
to Mimir's working directory. Its identity also includes the embedding provider
and model, so projects and embedding models never share vectors. Mimir loads a
matching cache on startup and builds it lazily when `search_code` is first used.

## First Run

At startup, Mimir probes the default native Ollama endpoint:

```text
http://localhost:11434
```

If Ollama is available, Mimir saves a default provider configuration. If it is
not available, the application enters its setup flow to collect an endpoint URL
and optional API key, then saves the resulting configuration after a successful
probe.

Mimir probes existing Ollama providers at startup to refresh their model lists
for commands such as `/models`. A malformed configuration enters setup mode
without overwriting the existing file.

## Configuration Format

The initial configuration shape is:

```json
{
  "selectedProvider": "ollama",
  "selectedModel": "",
  "embeddingProvider": "",
  "embeddingModel": "",
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

`selectedProvider` and `selectedModel` configure the chat model.
`embeddingProvider` and `embeddingModel` configure semantic code search and
are intentionally independent. Select an embedding-capable provider and model
in the `Embedding Model` settings category before using `search_code`; Mimir
does not choose a default embedding model.

`contextWindows` optionally records a nonnegative manual context capacity for a
specific provider/model pair. A value of `0` means the capacity is unknown. For
Ollama, Mimir queries `/api/show` for a positive `model_info` key ending in
`.context_length`; a discovered value is used for the current run in preference
to this fallback. Missing or unsupported model metadata does not prevent chat.

## Permission Grants

Built-in file operations are confined to Mimir's active project directory.
Reads within that directory are allowed by default. Writes and commands require
approval unless a matching grant is configured. Grants are stored in the user
configuration and are scoped to one canonical project path.

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
    }
    {
      "kind": "mcpServer",
      "projectRoot": "/home/user/project",
      "mcpServer": "github"
    }
  ]
}
```

A `directorySubtree` grant applies only to writes within that directory. A
`commandPrefix` grant applies only when the command runs from the project root and
matches the configured command prefix. An `mcpServer` grant reserves server-level
trust for future MCP transport.

Malformed grants, paths outside their project root, and path traversal are
rejected while loading configuration.

## Diagnostics

Raw LLM HTTP response output from the latest chat request is written to:

```text
$HOME/.cache/mimir/last_session.log
```

The log is overwritten when a new chat request starts and appended as response
body or stream chunks arrive. It can contain model output and provider error
bodies, so treat it as local diagnostic data.
