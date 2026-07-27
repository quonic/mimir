# Code Index

`code_index` provides both local semantic search and exact text lookup for a
project workspace. It discovers supported source files, splits them into stable
line-based chunks, creates embeddings through `ai`, and persists vectors with
`vdb`.

## Lifecycle

The caller owns a `Code_Index`. Create it with `code_index_init`, optionally
load an existing database with `code_index_load`, and release it with
`code_index_destroy`.

`code_index_init` accepts the working directory, cache directory, embedding
provider, and embedding model. It finds the nearest Git project root and derives
a deterministic cache file beneath the supplied cache directory. The package does
not determine configuration paths or access application configuration.

Use `code_index_rebuild` with an `ai.Client` to collect, chunk, and embed source
files. Use `code_index_save` after rebuilding to persist the VDB database and a
source-content fingerprint. `code_index_load` compares that fingerprint with the
currently supported project sources and rejects a missing, malformed, or stale
cache so the caller can rebuild it.

`code_index_search_text` embeds a query and returns caller-owned search results.
Release them with `code_index_search_results_destroy`. Result locations and
bounded source excerpts are available through `code_index_search_result_location`
and `code_index_search_result_excerpt`.

`code_index_find_text` performs a case-sensitive literal search over the same
supported source files. It does not require an embedding client or a persisted
vector database. It is appropriate for identifier, signature, and literal
lookup; it returns one result for each matching line in source order.

## Dependencies

The package depends explicitly on sibling `ai` and `vdb` packages plus Odin core
libraries. It does not depend on the application host, configuration, permission
policy, terminal UI, or tool response formatting.
