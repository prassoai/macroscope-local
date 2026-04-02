# macroscope-local

Macroscope CLI release artifacts, installer, and packaged review plugins for Codex and Claude Code.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope`, auto-configures your shell PATH, and installs the packaged `macroscope` plugin for supported Codex and Claude Code setups.

If your `codex` CLI is too old to load local plugins, the installer will place a small wrapper in `~/.local/bin/codex` that forwards to the newer Codex.app bundled binary.

After installation:

- Run `macroscope` to launch the interactive wizard.
- Run `/macroscope` in Claude Code or `/macroscope:macroscope` in Codex to use the PR-aware review router.
