# AI Package

The `ai` package provides generalized chat-completions and embedding interfaces for:

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

## Generating Embeddings

OpenAI-compatible and native Ollama interfaces support embeddings. A single input
returns one vector:

```odin
embedding, err := ai.send_embedding(client, ai.Embedding_Request{
    model = "nomic-embed-text",
    input = "Search this source file",
})
if err == .None {
    // Use embedding.embedding and embedding.inputTokenCount.
    ai.embedding_response_destroy(&embedding)
}
```

Use `send_embeddings` when the caller has multiple inputs. The response vectors
preserve the order of the request inputs:

```odin
response, err := ai.send_embeddings(client, ai.Embedding_Batch_Request{
    model = "nomic-embed-text",
    inputs = []string{"first document", "second document"},
    options = ai.Embedding_Options{
        dimensions = 256,
        hasDimensions = true,
    },
})
if err == .None {
    // Use response.embeddings.
    ai.embedding_batch_response_destroy(&response)
}
```

`Embedding_Response` and `Embedding_Batch_Response` own their model strings and
vector buffers. Always call the matching destroy procedure with the allocator used
for the request result.

Dimensions are sent to OpenAI-compatible and native Ollama APIs when
`hasDimensions` is set. Native Ollama also supports optional `ollamaTruncate`,
`ollamaKeepAlive`, and `ollamaOptions` controls. Set the corresponding `has...`
field to include each control. Unset controls are omitted from the request, so
Ollama retains its defaults, including its default truncation behavior.

The normalized response exposes `model`, vectors, `inputTokenCount`,
`totalDuration`, and `loadDuration`. A provider that does not return a metadata
value leaves it as zero. Anthropic interfaces return `.Unsupported_Interface`
because Anthropic does not provide a native embeddings endpoint.

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
    - `AI_OLLAMA_EMBEDDING_MODEL=<installed-embedding-model>` for embedding tests
   - Native endpoint: `AI_OLLAMA_ENDPOINT=http://127.0.0.1:11434`
   - OpenAI-compatible endpoint: `AI_OLLAMA_ENDPOINT=http://127.0.0.1:11434/v1`
   - Optional: `AI_OLLAMA_API_KEY=<value>`
3. Run `odin test ./ai`.

When integration is enabled, tests verify both chat completions and `list_models`
against the selected Ollama endpoint.
