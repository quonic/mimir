# Tools, MCP, and Skills

Mimir defines registries for built-in tools, MCP server configurations, and
skills. Tool calls are canonicalized through a permission dispatcher before a
built-in procedure can execute.

File reads are limited to the active project directory. Writes, shell commands,
and remote MCP actions are denied or require approval unless a matching session
or persisted permission grant allows them. Command grants bind the project root,
selected shell, and command prefix; commands with custom environment values
continue to require approval.

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
