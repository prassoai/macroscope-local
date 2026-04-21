# macroscope-local

Macroscope CLI release artifacts plus the installer for Codex, Claude Code, Cursor, and OpenCode.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer downloads `macroscope`, auto-configures your shell PATH, and installs the released Macroscope integration for supported Codex, Claude Code, Cursor, and OpenCode setups.
It also repairs stale Macroscope-owned binaries, plugin state, and legacy MCP registrations before laying down the fresh install.
Normal installs preserve `~/.macroscope` and saved credentials; they do not perform a destructive wipe.
For a full local removal after the CLI is available, run `macroscope uninstall`.

If your `codex` CLI is too old to load local plugins, the installer will place a small wrapper in `~/.local/bin/codex` that forwards to the newer Codex.app bundled binary.

The full public Macroscope plugin bundle is authored in the `back` repo under `tools/cmd/macrodaemon/public-plugin/`. This repo distributes the released CLI and installer. For local development, set `MACROSCOPE_LOCAL_BACK_REPO` and the installer will load the full plugin bundle directly from that back worktree.

After installation:

- Run `macroscope` to launch the interactive wizard.
- Run the local Macroscope review from your editor:
  - Claude Code: `/macroscope:codereview`
  - Claude Code autopilot: `/macroscope:autoloop`
  - Codex: `/macroscope:codereview`
  - Codex autopilot: `/macroscope:autoloop`
  - Cursor: `/macroscope:codereview`
  - Cursor autopilot: `/macroscope:autoloop`
  - OpenCode: `/macroscope`
  - OpenCode autopilot: `/macroscope-autoloop`
- `/macroscope:codereview` runs the local CLI review, launches a background worker in Claude Code, and validates each streamed issue before acting.
- `/macroscope:autoloop` runs the full review-fix-push-re-review autopilot cycle.

Normal installs fetch the plugin bundle from GitHub release assets, so the shipped plugin bundle and released CLI come from the same `back/macroscope-local` release pipeline.

For local development previews, point the installer at a back worktree:

```bash
MACROSCOPE_LOCAL_BACK_REPO=/path/to/back-worktree ./install.sh
```
