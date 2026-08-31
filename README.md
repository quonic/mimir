# Mimir

[![CI](https://github.com/quonic/mimir/actions/workflows/ci.yml/badge.svg)](https://github.com/quonic/mimir/actions/workflows/ci.yml)

A terminal-native, repository-aware AI coding agent for Ollama, written in Odin.

Mimir lets you work with an AI assistant directly from a project directory. It
streams conversations in a terminal UI, understands the active repository, and
can use tools to inspect and modify project files, run shell commands, and
search the codebase. Tool calls are subject to project-root boundaries and
configurable permission approval, with optional safety analysis for risky
actions.

Mimir also supports delegated subagents for self-contained tasks and a headless
JSONL interface for automation and integration with other tools.

The project started as a way to learn how agent systems work while building a
usable coding assistant in Odin that works with local Ollama models.

Mimir takes its name from Mímir, the Norse figure associated with wisdom and counsel.

## Preview

```text

 system: Mimir the terminal harness is ready.
   ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐
   │Categories          | Providers                                                       │
   │                    |                                                                 │
   │* Providers         | > Provider: < ollama >                                          │
   │  Chat Model        |   Name: ollama                                                  │
   │  Embedding Model   |   Type: < ollama >                                              │
   │  Safety Model      |   Endpoint: http://localhost:11434                              │
   │  Advanced          |   API key: ********                                             │
   │  Skills            |   Configured model: qwen3.8:27b-mtp-q8_0                        │
   │                    |   Context window tokens: 262144                                 │
   │                    |   [x] Enabled                                                   │
   │                    |   [ Refresh models ]                                            │
   │                    |   [ Add provider ]                                              │
   │                    |   [ Remove provider ]                                           │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │Arrows move  Tab change pane  Enter select/edit  Esc close                            │
   └──────────────────────────────────────────────────────────────────────────────────────┘



───────────────────────────────────────────────────────────────────────────────────────────────


Config: arrows/Tab, Enter, Esc
```

```text

 system: Mimir the terminal harness is ready.
   ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐
   │Categories          | Providers                                                       │
   │                    |                                                                 │
   │* Providers         | > Provider: < GoModel >                                         │
   │  Chat Model        |   Name: GoModel                                                 │
   │  Embedding Model   |   Type: < openai >                                              │
   │  Safety Model      |   Endpoint: http://localhost:8080/v1                            │
   │  Advanced          |   API key: ********                                             │
   │  Skills            |   Configured model: qwen3.8                                     │
   │                    |   Context window tokens: 0                                      │
   │                    |   [x] Enabled                                                   │
   │                    |   [ Refresh models ]                                            │
   │                    |   [ Add provider ]                                              │
   │                    |   [ Remove provider ]                                           │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │Arrows move  Tab change pane  Enter select/edit  Esc close                            │
   └──────────────────────────────────────────────────────────────────────────────────────┘



───────────────────────────────────────────────────────────────────────────────────────────────


Provider selected for editing
```

```text

 system: Mimir the terminal harness is ready.
   ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐
   │Categories          | Chat Model                                                      │
   │                    |                                                                 │
   │  Providers         | > * ollama / qwen3.8:27b-mtp-q8_0                               │
   │* Chat Model        |     ollama / muse-glimmer:latest                                │
   │  Embedding Model   |     ollama / laguna-xs-2.1:q8_0                                 │
   │  Safety Model      |     ollama / laguna-s-2.1:latest                                │
   │  Advanced          |     ollama / gpt-oss:120b                                       │
   │  Skills            |     GoModel / qwen3.8                                           │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │Arrows move  Tab change pane  Enter select/edit  Esc close                            │
   └──────────────────────────────────────────────────────────────────────────────────────┘



───────────────────────────────────────────────────────────────────────────────────────────────


Model selected and saved
```

```text

 system: Mimir the terminal harness is ready.
   ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐
   │Categories          | Advanced                                                        │
   │                    |                                                                 │
   │  Providers         |   Approval method: < Approve SAFE >                             │
   │  Chat Model        |   Tool continuation limit: 1000                                 │
   │  Embedding Model   |   System prompt mode: < Append >                                │
   │  Safety Model      |   System prompt: Default                                        │
   │> Advanced          |   [ Reset system prompt ]                                       │
   │  Skills            |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │                    |                                                                 │
   │Arrows move  Tab change pane  Enter select/edit  Esc close                            │
   └──────────────────────────────────────────────────────────────────────────────────────┘



───────────────────────────────────────────────────────────────────────────────────────────────


Config: arrows/Tab, Enter, Esc
```

```text

 system: Mimir the terminal harness is ready.
   ┌─ Configuration ──────────────────────────────────────────────────────────────────────┐
   │Categories          | Skills                                                          │
   │                    |                                                                 │
   │  Providers         | > [ Refresh skills ]                                            │
   │  Chat Model        |   [x] find-skills                                               │
   │  Embedding Model   |   [x] ste-writing                                               │
   │  Safety Model      |   [x] gem-design-md-guidelines                                  │
   │  Advanced          |   [x] gem-devops-guidelines                                     │
   │* Skills            |   [x] setup-matt-pocock-skills                                  │
   │                    |   [x] tdd                                                       │
   │                    |   [x] wait-what                                                 │
   │                    |   [x] wizard                                                    │
   │                    |   [x] writing-for-agents                                        │
   │                    |   [x] wayfinder                                                 │
   │                    |   [x] triage                                                    │
   │                    |   [x] to-tickets                                                │
   │                    |   [x] to-spec                                                   │
   │                    |   [x] to-questionnaire                                          │
   │                    |   [x] resolving-merge-conflicts                                 │
   │                    |   [x] research                                                  │
   │Arrows move  Tab change pane  Enter select/edit  Esc close                            │
   └──────────────────────────────────────────────────────────────────────────────────────┘



───────────────────────────────────────────────────────────────────────────────────────────────


Skills refreshed
```

## Prerequisites

- [Odin](https://odin-lang.org/)
- Supported Providers:
  - [Ollama](https://ollama.com/) running locally with at least one model available
  - OpenAI API Compatible providers (e.g., OpenAI, Azure OpenAI, GoModel)
    - Ollama is still needed for embedding models even if using other providers for chat.

## Supported Platforms

- Linux
- Windows, in Windows Terminal. Plain `cmd.exe` (conhost) is best-effort and
  may not support mouse tracking on older Windows builds.

macOS is untested and may never be officially supported, as I do not have access to that platform. You are more than welcome to try building and running Mimir there, but I cannot guarantee that it will work. Feel free to open issues or PRs if you find problems or have suggestions for improvements.

## Quick Start

1. Start Ollama and download a model:

   ```sh
   ollama pull qwen3.8:latest
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

Prebuilt binaries are attached to each tagged release. See the
[release documentation](docs/releases.md) for the asset layout and for how to
verify a download.

## Documentation

See the [documentation index](docs/README.md) for configuration, architecture,
tools and skills, and the AI package.
