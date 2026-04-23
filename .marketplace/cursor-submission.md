# Cursor Marketplace Submission

## Plugin Metadata

- **Name:** macroscope
- **Display Name:** Macroscope
- **Version:** 1.5.0
- **Author:** Prasso (https://github.com/prassoai)
- **Category:** developer-tools
- **Tags:** review, quality, automation, code-review
- **License:** MIT (required for Cursor marketplace)

## Short Description

Local-first AI code review — validates findings, rejects false positives, fixes real issues.

## Long Description

Macroscope runs deep code reviews locally using Cursor's agent. Two skills:

- **`/codereview`** — Streaming local review. Validates each finding, rejects false positives, fixes confirmed issues in an isolated worktree. Reports results by severity.
- **`/autoloop`** — Full autopilot: review → fix → verify → re-review → repeat (up to 5 iterations).

Your code stays local. Reviews run on your machine via the Macroscope CLI.

## Open Source Requirement

This repo is MIT-licensed. The skills and plugin wrapper are fully open source.
The Macroscope CLI binary is distributed as a free download.

## Prerequisites

```bash
curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
```

## URLs

- Source: https://github.com/prassoai/macroscope-local
- Logo: assets/macroscope.svg
