# Tools, MCP, and Skills

Mimir defines registries for built-in tools, MCP server configurations, and
skills. Tool calls are canonicalized through a permission dispatcher before a
built-in procedure can execute.

File reads are limited to the active project directory. Writes, shell commands,
and remote MCP actions are denied or require approval unless a matching session
or persisted permission grant allows them. Command grants bind the project root and
command prefix; commands must run from the project root to match.

## Semantic Code Search

`search_code` is a read-only built-in tool available to chat models. It accepts
a required natural-language `query` and an optional `max_results` value. The
tool embeds the query using the configured embedding model, searches the active
project's local vector index, and returns project-relative paths, line ranges,
and bounded excerpts from the current source files.

The initial search builds the index if a matching cache is unavailable. Searches
never read outside the active project, even if an old or malformed cached result
contains an invalid path. The tool returns at most ten matches, with excerpts
limited to 24 lines per match.

MCP JSON-RPC transport and provider-specific tool-call messages are follow-up
work. The dispatcher already reserves an MCP server identity boundary, but this
release does not launch servers or invoke remote tools.

## Skills

Skills are Markdown files. Global skills live under:

```text
$HOME/.config/mimir/skills/
```

Project-local skills live under:

```text
.mimir/skills/
```
