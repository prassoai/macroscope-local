# macroscope-local

Macroscope CLI release artifacts, installer, and packaged review workflows for Codex, Claude Code, Cursor, and OpenCode.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope`, auto-configures your shell PATH, and installs the packaged Macroscope integrations for supported Codex, Claude Code, Cursor, and OpenCode setups.

If your `codex` CLI is too old to load local plugins, the installer will place a small wrapper in `~/.local/bin/codex` that forwards to the newer Codex.app bundled binary.

After installation:

- Run `macroscope` to launch the interactive wizard.
- Run the PR-aware review router from your editor:
  - Claude Code: `/macroscope`
  - Codex: `/macroscope:macroscope`
  - Cursor: `/macroscope:macroscope`
  - OpenCode: `/macroscope`
- The router first checks whether the current local `HEAD` already has a successful `Macroscope - Correctness Check`; if not, it runs the local CLI path.
