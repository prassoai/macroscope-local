# macroscope plugin

Public Macroscope plugin files for Codex, Claude Code, Cursor, and OpenCode.

This directory is the source of truth for the shipped Macroscope plugin bundle. The `macroscope-local` release pipeline packages it and publishes it for installation.

The public entrypoints are two separate skills:

```text
Claude Code: /macroscope:codereview   /macroscope:autoloop
Codex:       /macroscope:codereview   /macroscope:autoloop
Cursor:      /codereview              /autoloop
OpenCode:    /macroscope-codereview   /macroscope-autoloop
```

`/macroscope:codereview` (or the host equivalent) runs a one-shot local review:

- It runs a streaming local `macroscope codereview`.
- In Claude Code, the skill dispatches a dedicated background worker subagent before the CLI starts.
- In other hosts, the installed skill is responsible for opening a sub-agent when the host supports it.
- It validates each streamed issue before acting.
- It rejects false positives, fixes confirmed issues one at a time, and reports only the issues it addressed, grouped by severity (critical / high / medium / low).
- It keeps polling sleeps capped at 60 seconds.

`/macroscope:autoloop` is the autopilot path:

- Run the local review.
- Fix valid findings directly in the working tree.
- Commit the fixes.
- Re-review to catch regressions.
- Repeat until there is nothing left to address (up to 5 iterations).

The installer in the repo root installs both the CLI and these packaged workflows for supported local Codex, Claude Code, Cursor, and OpenCode setups:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

For Codex terminal sessions, the installer will automatically prefer the newer Codex.app CLI when the `codex` command on your PATH is too old to load local plugins.

For local previews of unpublished plugin-skill changes from `back`, install with:

```bash
MACROSCOPE_LOCAL_BACK_REPO=/path/to/back-worktree ./install.sh
```
