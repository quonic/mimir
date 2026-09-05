# AI Package

The `ai` package provides chat completion and embedding interfaces for:

- Native Ollama endpoints

## Registering Interfaces

```odin
import "mimir/ai"

ai.add_interface("ollama", .Ollama, "http://127.0.0.1:11434")
```

Optional model allowlist:

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

Native Ollama interfaces can stream chat
updates:

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

Native Ollama and OpenAI-compatible interfaces support embeddings. One input
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

OpenAI-compatible `/models` responses carry no capability data. Mimir uses
models.dev as supplementary metadata when it is available, preferring its
OpenAI branch and falling back to other provider branches for compatible local
model IDs.
The metadata identifies embedding output, tool support, and positive context
limits. The `/models` response remains authoritative for the model list.

If models.dev is unavailable or does not contain a listed model, Mimir keeps
the name-based fallback: an id containing "embed" is treated as an embedding
model (for example `text-embedding-3-small`, `nomic-embed-text-v2-moe`,
`qwen3-embedding`, or `embeddinggemma`). A missing context limit does not erase
an existing manual limit. Use `ai.model_supports_embeddings` and
`ai.model_supports_chat` to filter the results.

Use `send_embeddings` for multiple inputs. The response vectors keep the order
of the request inputs:

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
vector buffers. Always call the matching destroy procedure with the allocator
that received the request result.

Mimir sends dimensions to native Ollama APIs when
`hasDimensions` is set. Native Ollama also supports `ollamaTruncate`,
`ollamaKeepAlive`, and `ollamaOptions`. Set the matching `has...` field to send
each option. Mimir omits unset options. Ollama then uses its defaults, including
its default truncation behavior.

The response includes `model`, vectors, `inputTokenCount`, `totalDuration`, and
`loadDuration`. A missing metadata value is zero. Anthropic interfaces return
`.Unsupported_Interface` because Anthropic has no native embeddings endpoint.

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

Local Ollama integration is optional:

1. Start Ollama and make sure that a model is available.
2. Set these environment variables:
   - `AI_OLLAMA_INTEGRATION=1`
   - `AI_OLLAMA_NATIVE_INTEGRATION=1` for the native `/api` protocol
   - `AI_OLLAMA_MODEL=<installed-model>`
   - `AI_OLLAMA_EMBEDDING_MODEL=<installed-embedding-model>` for embedding tests
   - Native endpoint: `AI_OLLAMA_ENDPOINT=http://127.0.0.1:11434`
   - Optional: `AI_OLLAMA_API_KEY=<value>`
3. Run `odin test ./ai`.

When integration is enabled, tests check chat completions and `list_models` at
the selected Ollama endpoint.
