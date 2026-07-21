# Macroscope CLI

Local-first AI code review for your terminal and editor, with an optional autopilot loop. Integrates with Claude Code, Codex, Cursor, and OpenCode.

Using the Macroscope CLI requires an active Macroscope account.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer previews every planned change — binaries, PATH edits, editor integrations, and permissions — and asks for confirmation before writing anything. It stages and validates the new binary and plugin bundle before replacing existing state, and preserves `~/.macroscope`, saved credentials, unrelated editor settings, and file modes.

## Quick start

Launch the interactive wizard:

```bash
macroscope
```

Run a review from your editor:

| Editor      | Review                   | Autopilot                |
| ----------- | ------------------------ | ------------------------ |
| Claude Code | `/macroscope:codereview` | `/macroscope:autoloop`   |
| Codex       | `/macroscope:codereview` | `/macroscope:autoloop`   |
| Cursor      | `/macroscope:codereview` | `/macroscope:autoloop`   |
| OpenCode    | `/macroscope`            | `/macroscope-autoloop`   |

- **Review** runs the local CLI review and validates each issue before acting.
- **Autopilot** runs the full review → fix → re-review cycle.

## Install options

Preview without writing, or install only the editors you use:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh |
  bash -s -- --dry-run --tools claude,codex --host-permissions skip --no-path
```

| Flag                       | Description                                                                     |
| -------------------------- | ------------------------------------------------------------------------------- |
| `--dry-run`                | Show the plan without making persistent writes                                  |
| `--tools <list>`           | Comma-separated editors to integrate (`claude`, `codex`, `cursor`, `opencode`)  |
| `--host-permissions grant` | Let editors auto-approve Macroscope commands instead of prompting each time     |
| `--host-permissions skip`  | Leave permissions unchanged (editors may prompt per command)                    |
| `--no-path`                | Make no shell or PATH edits                                                     |
| `--shell-config <path>`    | Write PATH changes to a specific dotfile                                         |
| `--yes`                    | Confirm the displayed plan non-interactively (never implies a permission grant) |

Integrations honor `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_CONFIG_DIR`, and Cursor's `~/.cursor` locations when set.

## Uninstall

```bash
macroscope uninstall
```

## Documentation

Full documentation is available at [docs.macroscope.com/cli](https://docs.macroscope.com/cli).

## License

MIT © Prasso, Inc. See [LICENSE](LICENSE).
