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
  "skillPaths": []
}
```

## Diagnostics

Raw LLM HTTP response output from the latest chat request is written to:

```text
$HOME/.cache/mimir/last_session.log
```

The log is overwritten when a new chat request starts and appended as response
body or stream chunks arrive. It can contain model output and provider error
bodies, so treat it as local diagnostic data.
