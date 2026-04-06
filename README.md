# macroscope-local

Macroscope CLI release artifacts, installer, and packaged plugin files for Codex, Claude Code, Cursor, and OpenCode.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope`, auto-configures your shell PATH, and installs the packaged Macroscope integration for supported Codex, Claude Code, Cursor, and OpenCode setups.

If your `codex` CLI is too old to load local plugins, the installer will place a small wrapper in `~/.local/bin/codex` that forwards to the newer Codex.app bundled binary.

The public Macroscope plugin skill is authored in the `back` repo under `tools/cmd/macrodaemon/public-plugin/`. This repo packages that skill for editor hosts. For local development, if `MACROSCOPE_LOCAL_BACK_REPO` is set, the installer automatically syncs the packaged skill file from that back worktree before installing the plugin bundle.

After installation:

- Run `macroscope` to launch the interactive wizard.
- Run the local Macroscope review from your editor:
  - Claude Code: `/macroscope`
  - Claude Code autopilot: `/macroscope loop`
  - Codex: `/macroscope:macroscope`
  - Codex autopilot: `/macroscope:macroscope loop`
  - Cursor: `/macroscope:macroscope`
  - Cursor autopilot: `/macroscope:macroscope loop`
  - OpenCode: `/macroscope`
  - OpenCode autopilot: `/macroscope loop`
- `/macroscope` runs the local CLI review path by default and validates each streamed issue before acting.
- `/macroscope loop` runs the full review-fix-push-re-review autopilot cycle.

Normal installs fetch the packaged plugin bundle from GitHub release assets so the shipped skill stays aligned with the released CLI.

To refresh the packaged plugin skill in this repo from a back worktree during local development, run:

```bash
scripts/sync-back-skills.sh /path/to/back-worktree
```
