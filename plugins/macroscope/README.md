# macroscope plugin

Packaged review workflows for Codex and Claude Code.

The primary entrypoint is:

```text
Claude Code: /macroscope
Codex:       /macroscope:macroscope
```

That router behaves differently depending on the current local `HEAD`:

- If the current local `HEAD` already has a completed `Macroscope - Correctness Check`, it uses the PR-comment triage workflow.
- Otherwise, it runs a streaming local `macroscope codereview`, fixes valid findings, and reports only the issues it addressed.

The installer in the repo root installs both the CLI and this plugin for supported local Codex and Claude setups:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

For Codex terminal sessions, the installer will automatically prefer the newer Codex.app CLI when the `codex` command on your PATH is too old to load local plugins.
