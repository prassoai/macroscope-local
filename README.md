# macroscope-local

Macroscope CLI release artifacts, installer, and Claude Code plugin marketplace source.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope` and `macroscope-mcp`, then auto-configures supported local AI tools.

## Claude Plugin Marketplace

This repository also acts as a Claude Code plugin marketplace with one plugin:

- `macroscope-codereview`

Manual install (if needed):

```bash
claude plugin marketplace add prassoai/macroscope-local
claude plugin install --scope user macroscope-codereview@macroscope-local
```

The plugin configures Macroscope's MCP server for Claude Code, using binaries installed by `install.sh`.
