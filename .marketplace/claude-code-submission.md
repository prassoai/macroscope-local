# Claude Code Official Marketplace Submission

## Plugin Metadata

- **Name:** macroscope
- **Version:** 1.5.0
- **Author:** Prasso (https://github.com/prassoai)
- **Category:** Development
- **License:** MIT

## Short Description

Local-first AI code review with an optional autopilot loop.

## Long Description

Macroscope runs deep code reviews locally using your coding agent. Two skills:

**`/macroscope:codereview`** runs a streaming local CLI review. It validates each finding against the actual code, rejects false positives, fixes confirmed issues in an isolated worktree, and reports results grouped by severity (critical, high, medium, low).

**`/macroscope:autoloop`** runs the full autopilot cycle: review → fix → verify → re-review → repeat until the branch is clean (up to 5 iterations).

Reviews run locally — your code never leaves your machine unless you push it.

## Skills

1. **codereview** — One-shot streaming local review with validation and worktree isolation
2. **autoloop** — Full review-fix-push-re-review autopilot cycle

## Capabilities

- Interactive (streams review findings in real-time)
- Write (fixes confirmed issues in code)

## Integration Details

- Installs a PreToolUse hook for `macroscope` and `mktemp` auto-approval
- Dispatches a dedicated background worker subagent for the review process
- Host-specific skill overlays optimize for Claude Code's Bash/Edit tooling

## Prerequisites

Macroscope CLI must be installed:
```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

## URLs

- Homepage: https://github.com/prassoai/macroscope-local
- Repository: https://github.com/prassoai/macroscope-local
- Privacy Policy: https://app.macroscope.com/privacy
- Terms of Service: https://app.macroscope.com/terms
