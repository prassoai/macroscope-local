# macroscope-local

Macroscope CLI release artifacts plus the installer for Codex, Claude Code, Cursor, and OpenCode.

## Install Macroscope

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer first displays every planned binary, PATH, integration, permission, and wizard action, then asks for confirmation. Initial interactive installs present all four host integrations as selected by default and launch setup after a successful install.
It stages and validates the new binary and plugin bundle before replacing install-owned state. Normal installs preserve `~/.macroscope`, saved credentials, unrelated host settings, and file modes.
For a full local removal after the CLI is available, run `macroscope uninstall`.

Preview an install without persistent writes, or select only the hosts you use:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh |
  bash -s -- --dry-run --tools claude,codex --host-permissions skip --no-path
```

`--host-permissions grant` separately opts into Macroscope/mktemp shell allow-rules and the Claude Code `PreToolUse` hook. `--yes` confirms the displayed plan but never implies that permission grant. PATH changes are skipped when `~/.local/bin` is already active; otherwise only the login shell's preferred file is changed. Use `--shell-config PATH` for a managed dotfile or `--no-path` to make no shell edits; the installer remembers either choice for future updates.

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
