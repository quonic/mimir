# Tools, MCP, and Skills

Mimir has registries for built-in tools, MCP server configurations, and skills.
The permission dispatcher checks each tool call before it runs a built-in
procedure.

File reads are limited to the active project directory. Writes, shell commands,
and remote MCP actions need approval or a matching permission grant. Command
grants include a project root and command prefix. The command must run from the
project root.

## Code Search

`search_code` is a read-only semantic search tool for chat models. It takes a
required natural-language `query` and an optional `max_results` value. It uses
the configured embedding model to search the active project's local vector
index. It returns project-relative paths, line ranges, and short excerpts from
current source files. Results are likely matches. They do not prove that a
symbol or literal is absent.

The first search builds the index when no matching cache exists. Searches never
read outside the active project, even when a cached result has an invalid path.
Mimir rebuilds the index after supported source files change. The tool returns
at most ten matches. Each excerpt has at most 24 lines.

`find_code` is a read-only exact-text search tool. It takes the same arguments.
It searches supported source files directly, without an embedding provider or
vector index. Use it for identifiers, signatures, and literals. It returns
matching lines in source order. It returns at most ten matches.

MCP JSON-RPC transport and provider-specific tool-call messages are not
available yet. The dispatcher reserves an identity boundary for an MCP server.
This release does not start servers or call remote tools.

## Skills

Skills are Markdown files. Global skills live under:

```text
$HOME/.config/mimir/skills/
```

Project-local skills live under:

```text
.mimir/skills/
```
