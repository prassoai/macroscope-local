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
