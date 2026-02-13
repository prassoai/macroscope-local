# macroscope-codereview plugin

Claude Code plugin that exposes the Macroscope local code review MCP server.

## Prerequisites

Install Macroscope and macroscope-mcp first:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

## Install from marketplace

```bash
claude plugin marketplace add prassoai/macroscope-local
claude plugin install --scope user macroscope-codereview@macroscope-local
```

Restart Claude Code after installation.

## Execution notes

Code reviews can take several minutes (up to 10 min for large diffs). Reviews run in the
foreground — MCP tools are not available in Claude Code background subagents (documented
limitation), so background execution via `run_in_background: true` will hang indefinitely.
