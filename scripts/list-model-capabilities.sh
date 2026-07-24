#!/usr/bin/env bash

# This script lists the available embedding models from the Ollama server.
SERVER=${SERVER:-"localhost"}
SERVER_URL="http://$SERVER:11434"

# Get the available models from the Ollama server and filter for embedding models
# curl "$SERVER_URL/api/tags"
# Example Output:
# {"models":[{"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","modified_at":"2026-07-22T01:01:30.30933824-05:00","size":274302450,"digest":"0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f","details":{"parent_model":"","format":"gguf","family":"nomic-bert","families":["nomic-bert"],"parameter_size":"137M","quantization_level":"F16","context_length":2048,"embedding_length":768},"capabilities":["embedding"]},{"name":"qwen3-coder:30b","model":"qwen3-coder:30b","modified_at":"2026-07-13T23:47:33.688779778-05:00","size":18556700761,"digest":"06c1097efce0431c2045fe7b2e5108366e43bee1b4603a7aded8f21689e90bca","details":{"parent_model":"","format":"gguf","family":"qwen3moe","families":["qwen3moe"],"parameter_size":"30.5B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":2048},"capabilities":["completion","tools"]},{"name":"gpt-oss:120b","model":"gpt-oss:120b","modified_at":"2026-07-13T18:42:05.845959065-05:00","size":65369818941,"digest":"a951a23b46a1f6093dafee2ea481d634b4e31ac720a8a16f3f91e04f5a40ecd9","details":{"parent_model":"","format":"gguf","family":"gptoss","families":["gptoss"],"parameter_size":"116.8B","quantization_level":"MXFP4","context_length":131072,"embedding_length":2880},"capabilities":["completion","tools","thinking"]},{"name":"qwen3.6:35b","model":"qwen3.6:35b","modified_at":"2026-07-13T18:31:20.801814065-05:00","size":23938333577,"digest":"07d35212591fc27746f0a317c975a6d68754fb38e9053d82e25f06057af28522","details":{"parent_model":"","format":"gguf","family":"qwen35moe","families":["qwen35moe"],"parameter_size":"36.0B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":2048},"capabilities":["vision","completion","tools","thinking"]},{"name":"gemma4:31b","model":"gemma4:31b","modified_at":"2026-07-13T18:26:23.707785789-05:00","size":19868981791,"digest":"6316f0629137b426c9d9b853ffc4c8209589f30ee39aebede6285096c0ff47e7","details":{"parent_model":"","format":"gguf","family":"gemma4","families":["gemma4"],"parameter_size":"31.3B","quantization_level":"Q4_K_M"},"capabilities":["completion","tools","thinking"]},{"name":"ornith:35b","model":"ornith:35b","modified_at":"2026-07-13T18:21:22.728757146-05:00","size":21166759599,"digest":"5a470e0f652cac9b5a375fd58d67831d48be07a1cc4ed3f7250ca4875b3226d8","details":{"parent_model":"","format":"gguf","family":"qwen35moe","families":["qwen35moe"],"parameter_size":"34.7B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":2048},"capabilities":["completion","tools","thinking"]}]}

echo "Available embedding models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("embedding")) | .name'
echo "Available thinking models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("thinking")) | .name'
echo "Available completion models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("completion")) | .name'
echo "Available tools models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("tools")) | .name'
echo "Available vision models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("vision")) | .name'
echo "Available audio models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("audio")) | .name'
echo "Available video models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("video")) | .name'
echo "Available code models:"
curl -s "$SERVER_URL/api/tags" | jq -r '.models[] | select(.capabilities | index("code")) | .name'

# Example Output:
# Available embedding models:
# nomic-embed-text:latest
# Available thinking models:
# gpt-oss:120b
# qwen3.6:35b
# gemma4:31b
# ornith:35b
# Available completion models:
# qwen3-coder:30b
# gpt-oss:120b
# qwen3.6:35b
# gemma4:31b
# ornith:35b
# Available tools models:
# qwen3-coder:30b
# gpt-oss:120b
# qwen3.6:35b
# gemma4:31b
# ornith:35b
# Available vision models:
# qwen3.6:35b
# Available audio models:
# Available video models:
# Available code models: