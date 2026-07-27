# Mimir

A flicker free terminal harness for agentic coding, written in Odin.

I started this to primarily learn how an agent harness works, and secondarily make a
harness in Odin that works first with Ollama.

Mimir takes its name from Mímir, the Norse figure associated with wisdom and counsel.

## Preview

```text
┌─ History ──────────────────────────────────────────────────────────────────────────────────┐
│system: Mimir the terminal harness is ready.                                                │
│  ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐  │
│  │Categories          | Providers                                                       │  │
│  │                    |                                                                 │  │
│  │* Providers         |   Provider: < Ollama Internal Test Server >                     │  │
│  │  Chat Model        |   Name: Ollama Internal Test Server                             │  │
│  │  Embedding Model   |   Type: < ollama >                                              │  │
│  │  Safety Model      | > Endpoint: http://ollama-test.local:11434                      │  │
│  │  Advanced          |   API key: ********                                             │  │
│  │                    |   Configured model: qwen3.6:35b                                 │  │
│  │                    |   Context window tokens: 262144                                 │  │
│  │                    |   [x] Enabled                                                   │  │
│  │                    |   [ Refresh models ]                                            │  │
│  │                    |   [ Add provider ]                                              │  │
│  │                    |   [ Remove provider ]                                           │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │Arrows move  Tab change pane  Enter select/edit  Esc close                            │  │
│  └──────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ Input ────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
Config: arrows/Tab, Enter, Esc
```

```text
┌─ History ──────────────────────────────────────────────────────────────────────────────────┐
│system: Mimir the terminal harness is ready.                                                │
│  ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐  │
│  │Categories          | Chat Model                                                      │  │
│  │                    |                                                                 │  │
│  │  Providers         |     Ollama Internal Test Server / granite4.1-guardian:8b        │  │
│  │> Chat Model        |     Ollama Internal Test Server / qwen3-coder:30b               │  │
│  │  Embedding Model   |     Ollama Internal Test Server / gpt-oss:120b                  │  │
│  │  Safety Model      |   * Ollama Internal Test Server / qwen3.6:35b                   │  │
│  │  Advanced          |     Ollama Internal Test Server / gemma4:31b                    │  │
│  │                    |     Ollama Internal Test Server / ornith:35b                    │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │Arrows move  Tab change pane  Enter select/edit  Esc close                            │  │
│  └──────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ Input ────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
Config: arrows/Tab, Enter, Esc
```

```text
┌─ History ──────────────────────────────────────────────────────────────────────────────────┐
│system: Mimir the terminal harness is ready.                                                │
│  ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐  │
│  │Categories          | Advanced                                                        │  │
│  │                    |                                                                 │  │
│  │  Providers         |   Approval method: < Approve SAFE >                             │  │
│  │  Chat Model        |   Tool continuation limit: 1000                                 │  │
│  │  Embedding Model   |                                                                 │  │
│  │  Safety Model      |                                                                 │  │
│  │> Advanced          |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │                    |                                                                 │  │
│  │Arrows move  Tab change pane  Enter select/edit  Esc close                            │  │
│  └──────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ Input ────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────┘
Config: arrows/Tab, Enter, Esc
```

## Prerequisites

- [Odin](https://odin-lang.org/)
- [Ollama](https://ollama.com/) running locally with at least one model available

## Supported Platforms

- Linux

Windows and macOS are untested and may never be officially supported, as I do not have access to those platforms. You are more than welcome to try building and running Mimir on those platforms, but I cannot guarantee that it will work. Feel free to open issues or PRs if you find problems or have suggestions for improvements.

## Quick Start

1. Start Ollama and download a model:

   ```sh
   ollama pull llama3.2
   ```

2. Run Mimir from the repository root:

   ```sh
   odin run .
   ```

On first startup, Mimir detects the local Ollama endpoint at
`http://localhost:11434` and creates a default configuration when it is available.
For other providers and configuration details, see the
[configuration documentation](docs/configuration.md).

## Text Selection

Drag to select text in the History or Input panel. In Input, `Shift` with the
arrow, Home, or End keys extends the selection, and `Ctrl+A` selects all input.
`Ctrl+C` or `Ctrl+Insert` copies the active selection; `Ctrl+X` cuts Input text
and copies immutable History text. `Shift+Insert` and other terminal paste
commands can paste multiline text into Input when the terminal supports
bracketed paste mode.

Clipboard writes use OSC 52, which must be enabled by the terminal or terminal
multiplexer for copied text to reach the system clipboard.

## Build From Source

From the repository root:

```sh
odin check .
odin test .
odin build .
```

## Documentation

See the [documentation index](docs/README.md) for configuration, architecture,
tools and skills, and the AI package.
