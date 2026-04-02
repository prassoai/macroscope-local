# macroscope plugin

Packaged review workflows for Codex, Claude Code, Cursor, and OpenCode.

The primary entrypoint is:

```text
Claude Code: /macroscope
Codex:       /macroscope:macroscope
Cursor:      /macroscope:macroscope
OpenCode:    /macroscope
```

That router behaves differently depending on the current local `HEAD`:

- If the current local `HEAD` already has a completed `Macroscope - Correctness Check`, it uses the PR-comment triage workflow.
- Otherwise, it runs a streaming local `macroscope codereview`, fixes valid findings, and reports only the issues it addressed.

The installer in the repo root installs both the CLI and these packaged workflows for supported local Codex, Claude Code, Cursor, and OpenCode setups:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

For Codex terminal sessions, the installer will automatically prefer the newer Codex.app CLI when the `codex` command on your PATH is too old to load local plugins.

The worker entrypoints are also installed:

```text
Claude Code: /triage-pr-comments, /respond-to-pr-comments, /review-pr, /local-review
Codex:       /macroscope:triage-pr-comments, /macroscope:respond-to-pr-comments, /macroscope:review-pr, /macroscope:local-review
Cursor:      /macroscope:triage-pr-comments, /macroscope:respond-to-pr-comments, /macroscope:review-pr, /macroscope:local-review
OpenCode:    /triage-pr-comments, /respond-to-pr-comments, /review-pr, /local-review
```
