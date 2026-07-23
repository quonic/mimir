# Mimir

A flicker free terminal harness for agentic coding, written in Odin.

I started this to primarily learn how an agent harness works, and secondarily make a
harness in Odin that works first with Ollama.

Mimir takes its name from Mímir, the Norse figure associated with wisdom and counsel.

## Screenshots

<img width="716" height="381" alt="image" src="https://github.com/user-attachments/assets/19dcde61-0422-44da-a0ef-142689724112" />
<img width="1300" height="970" alt="image" src="https://github.com/user-attachments/assets/84b64494-8280-4946-8a9b-2fd0e970c11b" />

## Prerequisites

- [Odin](https://odin-lang.org/)
- [Ollama](https://ollama.com/) running locally with at least one model available

## Supported Platforms

- Linux
- macOS might work, but is untested. Please report any issues if you try it.
- Windows might work, but is untested. Please report any issues if you try it.

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
