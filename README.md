# Mimir

A flicker free terminal harness for agentic coding, written in Odin.

I started this to primarily learn how an agent harness works, and secondarily make a
harness in Odin that works first with Ollama.

Mimir takes its name from Mímir, the Norse figure associated with wisdom and counsel.

<img width="944" height="582" alt="Screenshot_20260720_175632" src="https://github.com/user-attachments/assets/ae69833a-9e4e-4b84-a245-2ff2fec8dcbb" />

## Prerequisites

- [Odin](https://odin-lang.org/)
- [Ollama](https://ollama.com/) running locally with at least one model available

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
