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

| Agent         | Review                                          | Autopilot                                     |
| ------------- | ----------------------------------------------- | --------------------------------------------- |
| Claude Code   | `/macroscope:codereview`                        | `/macroscope:autoloop`                        |
| Codex         | `$macroscope:codereview`                        | `$macroscope:autoloop`                        |
| Cursor        | `/codereview`                                   | `/autoloop`                                   |
| OpenCode      | `/macroscope-codereview`                        | `/macroscope-autoloop`                        |
| Pi            | `/skill:macroscope-codereview`                  | `/skill:macroscope-autoloop`                  |
| Hermes Agent  | `/macroscope-codereview`                        | `/macroscope-autoloop`                        |
| OpenHands CLI | Ask it to use the `macroscope-codereview` skill | Ask it to use the `macroscope-autoloop` skill |

- **Review** runs a Macroscope review and reports validated issues without editing files.
- **Autopilot** runs the full review → fix → commit → re-review cycle. Add `--isolate` to work in a separate worktree, for example `/skill:macroscope-autoloop --isolate` in Pi.

Integrations call the `macroscope` CLI, which talks to Macroscope's hosted service; no local MCP server is needed. Restart an agent that was open during installation. In Pi, run `/reload` instead; Hermes picks up new skills with its next message, and OpenHands in a new conversation. The OpenHands integration is for the OpenHands CLI, not hosted OpenHands.

## Install options

Preview without writing, or install only the agents you use:

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh |
  bash -s -- --dry-run --tools claude,codex --no-path
```

| Flag                    | Description                                                                                                                    |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `--dry-run`             | Show the plan without making persistent writes                                                                                 |
| `--tools <list>`        | Comma-separated agents to integrate (`claude`, `codex`, `cursor`, `opencode`, `pi`, `hermes`, `openhands`), or `all` or `none` |
| `--no-path`             | Make no shell or PATH edits                                                                                                    |
| `--shell-config <path>` | Write PATH changes to a specific dotfile                                                                                       |
| `--yes`                 | Confirm the displayed plan non-interactively                                                                                   |
| `--no-wizard`           | Skip sign-in and workspace selection after installing                                                                          |

Integrations honor `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `OPENCODE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `HERMES_HOME`, and Cursor's `~/.cursor` locations when set. Pi, Hermes Agent, and the OpenHands CLI get two skills in `~/.pi/agent/skills`, `~/.hermes/skills`, and `~/.openhands/skills` by default. A custom Pi directory should be an absolute path; the installer records it for updates and uninstall, but Pi loads the skills only while `PI_CODING_AGENT_DIR` names it.

To change integrations on an existing install, pass `--tools` to `macroscope update`. The list replaces the saved selection, so name every agent to keep, for example `macroscope update --yes --tools claude,pi`. A plain `macroscope update` keeps the saved selection and does not add newly supported agents.

### Managed machines

Run the installer as each developer's own user, not as root:

```bash
curl -fsSL https://macroscope.com/install.sh |
  bash -s -- --yes --tools pi --no-wizard --no-path
```

Your provisioning tooling puts `~/.local/bin` on PATH and configures Pi and its model provider. Each developer then runs `macroscope setup` to sign in with their own GitHub account and choose a workspace, and `macroscope me` confirms it. Sign-in cannot be pre-provisioned or shared.

## Uninstall

```bash
macroscope uninstall
```

## Documentation

Full documentation is available at [docs.macroscope.com/cli](https://docs.macroscope.com/cli).

## Source

`install.sh`, the plugin bundle (`plugins/`, `.claude-plugin/`), and the standalone skills (`skills/`) are generated from Macroscope's main source repository and republished here with every release, so direct edits to them are replaced by the next release.

Issues and feedback are welcome here.

## License

MIT © Prasso, Inc. See [LICENSE](LICENSE).
