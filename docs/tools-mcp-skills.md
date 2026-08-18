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

## MCP (Model Context Protocol)

Mimir speaks the modern, stateless 2026-07-28 revision of MCP only. Each
request carries its own protocol version and capabilities; there is no
`initialize` handshake and no session state. Mimir does not fall back to
older, handshake-based servers.

Configured servers in `mcpServers` connect over one of two transports,
selected by which field is set:

- `command` (with optional `args`): spawns the server as a subprocess and
  exchanges newline-delimited JSON-RPC over its stdin/stdout.
- `url`: sends each JSON-RPC message as its own POST to a Streamable HTTP
  MCP endpoint.

Mimir calls `server/discover` on a server the first time it is used, and
caches the declared `tools`/`resources`/`prompts` capabilities for the rest of
the run. Tool names are prefixed with their server name to avoid collisions
across servers: a `search` tool on a server named `github` is exposed to the
model as `github.search`. Reading a resource or resolving a prompt uses the
same `{server}.{name}` convention.

Every MCP tool call requires the same approval a shell command or file write
does. The dispatcher grants approval per MCP server (not per tool): approving
one tool call on a server can grant session or persistent access to any tool
call on that same server, matching the existing `Command_Prefix` and
`Directory_Subtree` grant model.

Resources are not injected into the model's context automatically. A
`read_mcp_resource` builtin tool (arguments: `mcp_server`, `uri`) lets the
model pull a resource's contents into the conversation on demand, subject to
the same per-server approval.

Prompts are user-controlled, not model-controlled. Use `/prompts` to list all
prompts advertised by enabled servers, and
`/prompts <server>.<name> [json arguments]` to resolve one; the resolved
message text is appended to the conversation. There is no argument
auto-completion.

The following are not implemented in this release and are tracked as future
work: `subscriptions/listen` (live list-changed/resource-updated
notifications — tool, resource, and prompt lists are refreshed on demand
only), multi round-trip requests (elicitation, sampling, and roots —
a tool call that returns `resultType: "input_required"` is treated as a tool
execution error), the `x-mcp-header`/`Mcp-Param-*` HTTP parameter-mirroring
extension, and an HTTP authorization/OAuth framework for Streamable HTTP
servers that require it.

## Skills

Skills are Markdown files. Global skills live under:

```text
$HOME/.config/mimir/skills/
```

Project-local skills live under:

```text
.mimir/skills/
```
