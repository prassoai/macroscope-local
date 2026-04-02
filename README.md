# macroscope-local

Macroscope CLI release artifacts, installer, and packaged review plugins for Codex and Claude Code.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope`, auto-configures your shell PATH, and installs the packaged `macroscope` plugin for supported Codex and Claude Code setups.

After installation:

- Run `macroscope` to launch the interactive wizard.
- Run `/macroscope:review` in Codex or Claude Code to use the PR-aware review router.
