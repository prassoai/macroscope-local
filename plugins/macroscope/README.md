# macroscope plugin

Public Macroscope plugin files for Codex, Claude Code, Cursor, and OpenCode.

This directory is the source of truth for the shipped Macroscope plugin bundle. The `macroscope-local` release pipeline packages it and publishes it for installation.

The public entrypoints are two separate skills:

```text
Claude Code: /macroscope:codereview   /macroscope:autoloop
Codex:       $macroscope:codereview   $macroscope:autoloop
Cursor:      /codereview              /autoloop
OpenCode:    /macroscope-codereview   /macroscope-autoloop
```

The `codereview` skill runs a one-shot local review:

- It runs a local `macroscope codereview` against an isolated snapshot by default; explicit `--isolate=false` reviews in place. The CLI owns snapshot creation and cleanup.
- On hosts with background-command support, it runs the blocking review asynchronously while streaming issues back to the active session. Foreground-only hosts capture the full output before findings are validated and need a shell timeout of at least 30 minutes.
- It validates each streamed issue before reporting.
- It rejects false positives and reports only the confirmed findings, grouped by severity (critical / high / medium / low).
- It does not edit files — it is report-only.

The `autoloop` skill is the autopilot path:

- Run the local review.
- Fix valid findings directly in the working tree.
- Verify and commit the fixes.
- Re-review to catch regressions.
- Repeat until there is nothing left to address (up to 5 iterations).
- Supports `--isolate` to run the entire loop in a disposable worktree.

The installer in the repo root installs both the CLI and these packaged workflows for supported local Codex, Claude Code, Cursor, and OpenCode setups:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

For Codex terminal sessions, the installer will automatically prefer the newer Codex.app CLI when the `codex` command on your PATH is too old to load local plugins.

For local previews of unpublished plugin-skill changes from `back`, install with:

```bash
MACROSCOPE_LOCAL_BACK_REPO=/path/to/back-worktree ./install.sh
```
