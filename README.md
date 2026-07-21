# Macroscope CLI

**[Macroscope](https://macroscope.com)** is an AI code reviewer that catches bugs and helps you ship higher-quality code.

The **Macroscope CLI** brings code review directly to your terminal and coding agents, so you can trigger reviews without opening a pull request.

Using the Macroscope CLI requires an active Macroscope account.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

The installer previews every planned change — binaries, PATH edits, editor integrations, and permissions — and asks for confirmation before writing anything. It downloads over HTTPS only, verifies each downloaded artifact against the SHA-256 checksum GitHub reports for that release asset before installing it, and stages and validates the new binary and plugin bundle before replacing existing state. It preserves `~/.macroscope`, saved credentials, unrelated editor settings, and file modes.

A checksum **mismatch always aborts the install**, as does a failure to fetch the release metadata needed to verify (a network or server error is never treated as "no checksum"). If GitHub genuinely reports no checksum for an asset, the installer warns loudly and continues; set `MACROSCOPE_REQUIRE_CHECKSUM=1` to instead fail closed and refuse any download without a verified checksum.

This checksum verification protects against transport corruption and man-in-the-middle tampering of the download. It is **not** a defense against a compromised release or GitHub account — an attacker with release-write access controls both the artifact bytes and the checksum GitHub reports for them. Defending against that requires an independent signature (e.g. cosign/Sigstore) and is intentionally out of scope for this check.

Interactive installs propose command auto-approval by default; choose **Install without command auto-approval** at the final confirmation to decline.

Mandatory auto-updates reuse the integration and command-permission choices in the install manifest without showing the installer plan or asking for confirmation. If those saved choices are missing or incomplete, the installer falls back to the normal interactive selection and confirmation flow.

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
