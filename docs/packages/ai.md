# AI Package

The `ai` package provides a generalized chat-completions interface for:

- Native Ollama endpoints
- OpenAI-compatible endpoints, including Ollama's `/v1` compatibility API
- Anthropic message endpoints

## Registering Interfaces

```odin
import "mimir/ai"

ai.add_interface("ollama", .Ollama, "http://127.0.0.1:11434")
ai.add_interface("ollama-openai", .OpenAI, "http://127.0.0.1:11434/v1")
ai.add_interface("anthropic", .Anthropic, "https://api.anthropic.com/v1")
```

Optional model allow-list:

```odin
ai.add_interface_with_models(
    "ollama",
    .Ollama,
    "http://127.0.0.1:11434",
    []string{"llama3.2", "qwen2.5"},
)
```

## Sending a Chat Request

```odin
client, err := ai.new_client("ollama", "")
if err != .None {
    // Handle interface lookup failure.
}

response, err := ai.send_chat_completion(client, ai.Chat_Request{
    model = "llama3.2",
    messages = []ai.Message{{role = .User, content = "Say hello"}},
    temperature = 0.2,
    maxTokens = 64,
})
if err == .None {
    // Use response.content.
    delete(response.content)
    delete(response.model)
    delete(response.finishReason)
}
```

## Streaming a Chat Request

OpenAI-compatible, Anthropic, and native Ollama interfaces can stream chat
deltas:

```odin
stream_chat_delta :: proc(delta: ai.Chat_Stream_Delta) -> bool {
    if delta.content != "" {
        // Append or render delta.content.
    }

    return true // Return false to stop processing more deltas.
}

err := ai.send_chat_completion_stream(client, ai.Chat_Request{
    model = "llama3.2",
    messages = []ai.Message{{role = .User, content = "Say hello"}},
    temperature = 0.2,
    maxTokens = 64,
}, stream_chat_delta)
```

## Listing Models

```odin
models, err := ai.list_models(client)
if err == .None {
    for model in models {
        // Use model.
        delete(model)
    }
    delete(models)
}
```

## Verification

```sh
odin check .
odin test ./ai
```

Integration with local Ollama is opt-in:

1. Start Ollama and make sure a model is available.
2. Set these environment variables:
   - `AI_OLLAMA_INTEGRATION=1`
   - `AI_OLLAMA_NATIVE_INTEGRATION=1` for the native `/api` protocol
   - `AI_OLLAMA_MODEL=<installed-model>`
   - Native endpoint: `AI_OLLAMA_ENDPOINT=http://127.0.0.1:11434`
   - OpenAI-compatible endpoint: `AI_OLLAMA_ENDPOINT=http://127.0.0.1:11434/v1`
   - Optional: `AI_OLLAMA_API_KEY=<value>`
3. Run `odin test ./ai`.

When integration is enabled, tests verify both chat completions and `list_models`
against the selected Ollama endpoint.
