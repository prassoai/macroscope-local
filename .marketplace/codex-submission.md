# Codex Official Plugin Directory Submission

## Status

Self-serve publishing not yet available as of April 2026.
OpenAI curates the official directory. Monitor for self-serve launch.

## Plugin Metadata

- **Name:** macroscope
- **Display Name:** Macroscope
- **Version:** 1.5.0
- **Developer:** Prasso
- **Category:** Development
- **Capabilities:** Interactive, Write

## Interface Spec (already in .codex-plugin/plugin.json)

```json
{
  "displayName": "Macroscope",
  "shortDescription": "Local-first Macroscope code review and autopilot loop",
  "longDescription": "Two skills: /macroscope:codereview runs a streaming local CLI review, /macroscope:autoloop pushes fixes, waits for correctness checks, and addresses PR comments until the branch is clean.",
  "developerName": "Prasso",
  "category": "Development",
  "capabilities": ["Interactive", "Write"],
  "brandColor": "#0F766E",
  "composerIcon": "./assets/macroscope-small.svg",
  "logo": "./assets/macroscope.svg"
}
```

## Default Prompts

- `/macroscope:codereview`
- `/macroscope:autoloop`

## Installation Policy

- `INSTALLED_BY_DEFAULT` for marketplace installs
- `ON_USE` authentication (CLI login on first use)

## Codex-Specific Features

- Background process management with file-based logging and PID tracking
- Workaround for Codex tool-call timeout constraints
- mktemp-based unique log/PID files for concurrent session safety
- Codex CLI shim for older Codex versions (installed by install.sh)

## URLs

- Homepage: https://github.com/prassoai/macroscope-local
- Privacy Policy: https://app.macroscope.com/privacy
- Terms of Service: https://app.macroscope.com/terms
