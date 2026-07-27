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
  "toolContinuations": 1000,
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

`safetyProvider` and `safetyModel` set the model that checks shell commands in
the approval dialog. Select a chat provider and model in `Safety Model` to use
a separate safety model. If both values are empty, Mimir uses the chat provider
and model. An incomplete or invalid safety selection disables safety advice.

`toolContinuations` sets the maximum number of consecutive model and tool
continuation cycles for one request. It must be a positive integer and defaults
to `1000`. Change it through `/config` in `Advanced`, or edit the JSON file.

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
