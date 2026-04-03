# macroscope plugin

Packaged review workflows for Codex, Claude Code, Cursor, and OpenCode.

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

`/macroscope` now defaults to the local CLI review path:

- It runs a streaming local `macroscope codereview`.
- It validates each streamed issue before acting.
- It fixes only the valid findings and reports only the issues it addressed.
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

The explicit worker entrypoints are also installed:

```text
Claude Code: /macroscope-local-review, /macroscope-triage-pr-comments, /macroscope-respond-to-pr-comments, /macroscope-review-pr
Codex:       /macroscope:macroscope-local-review, /macroscope:macroscope-triage-pr-comments, /macroscope:macroscope-respond-to-pr-comments, /macroscope:macroscope-review-pr
Cursor:      /macroscope:macroscope-local-review, /macroscope:macroscope-triage-pr-comments, /macroscope:macroscope-respond-to-pr-comments, /macroscope:macroscope-review-pr
OpenCode:    /macroscope-local-review, /macroscope-triage-pr-comments, /macroscope-respond-to-pr-comments, /macroscope-review-pr
```
