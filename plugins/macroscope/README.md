# macroscope plugin

Packaged Macroscope plugin files for Codex, Claude Code, Cursor, and OpenCode.

The public Macroscope skill instructions live in the `back` repo under `tools/cmd/macrodaemon/public-plugin/`. The file under `plugins/macroscope/skills/macroscope/` in this repo is the packaged release copy used for plugin installation.

The primary entrypoint is:

```text
Claude Code: /macroscope
Claude Code: /macroscope loop
Codex:       /macroscope:macroscope
Codex:       /macroscope:macroscope loop
Cursor:      /macroscope:macroscope
Cursor:      /macroscope:macroscope loop
OpenCode:    /macroscope
OpenCode:    /macroscope loop
```

`/macroscope` is the only public entrypoint:

- It runs a streaming local `macroscope codereview`.
- It moves the streaming review into a sub-agent when the host supports one.
- It validates each streamed issue before acting.
- It rejects false positives, fixes confirmed issues one at a time, and reports only the issues it addressed.
- It keeps polling sleeps capped at 60 seconds.

`/macroscope loop` is the autopilot path:

- Run the local review.
- Fix valid findings.
- Push.
- Wait for a successful Macroscope correctness check on the current `HEAD`.
- Triage and address PR comments for that reviewed `HEAD`.
- Repeat until there is nothing left to address.

The installer in the repo root installs both the CLI and these packaged workflows for supported local Codex, Claude Code, Cursor, and OpenCode setups:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

For Codex terminal sessions, the installer will automatically prefer the newer Codex.app CLI when the `codex` command on your PATH is too old to load local plugins.

For local previews of unpublished plugin-skill changes from `back`, install with:

```bash
MACROSCOPE_LOCAL_BACK_REPO=/path/to/back-worktree ./install.sh
```
