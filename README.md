# Macroscope CLI

**[Macroscope](https://macroscope.com)** is an AI code reviewer that catches bugs and helps you ship higher-quality code.

The **Macroscope CLI** brings code review directly to your terminal and coding agents, so you can trigger reviews without opening a pull request.

Using the Macroscope CLI requires an active Macroscope account.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer previews every planned change — binaries, PATH edits, and editor integrations — and asks for confirmation before writing anything. It stages and validates the new binary and plugin bundle before replacing existing state, and preserves `~/.macroscope`, saved credentials, unrelated editor settings, and file modes.

The installer does not add standing shell allow-rules or approval hooks. Use the coding agent's own auto mode when you want an unattended review flow.

Mandatory auto-updates reuse the integration and PATH choices in the install manifest without showing the installer plan or asking for confirmation. If those saved choices are missing or incomplete, the installer falls back to the normal interactive selection and confirmation flow.

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
| Cursor      | `/codereview`            | `/autoloop`              |
| OpenCode    | `/macroscope-codereview` | `/macroscope-autoloop`   |

- **Review** runs the local CLI review and validates each issue before acting.
- **Autopilot** runs the full review → fix → re-review cycle.

## Install options

Preview without writing, or install only the editors you use:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh |
  bash -s -- --dry-run --tools claude,codex --no-path
```

| Flag                    | Description                                                                    |
| ----------------------- | ------------------------------------------------------------------------------ |
| `--dry-run`             | Show the plan without making persistent writes                                 |
| `--tools <list>`        | Comma-separated editors to integrate (`claude`, `codex`, `cursor`, `opencode`) |
| `--no-path`             | Make no shell or PATH edits                                                    |
| `--shell-config <path>` | Write PATH changes to a specific dotfile                                       |
| `--yes`                 | Confirm the displayed plan non-interactively                                   |

Integrations honor `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_CONFIG_DIR`, and Cursor's `~/.cursor` locations when set.

## Uninstall

```bash
macroscope uninstall
```

## Documentation

Full documentation is available at [docs.macroscope.com/cli](https://docs.macroscope.com/cli).

## License

MIT © Prasso, Inc. See [LICENSE](LICENSE).
