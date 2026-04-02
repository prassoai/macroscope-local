---
name: review
description: Main review entrypoint. If the current branch has an open PR, triage unresolved PR comments. If it does not, run a local Macroscope review, triage streaming findings, fix the valid ones, and report what was addressed.
---

Use this as the customer-facing review router.

This skill chooses between two different workflows:

- **Open PR on the current branch**: use the PR-comment path only. Do **not** run the Macroscope CLI. Follow the packaged `triage-pr-comments` skill and stop after triage.
- **No open PR on the current branch**: use the local CLI path only. Follow the packaged `local-review` skill, triage streaming findings from `macroscope codereview`, fix the valid ones, and report only what you addressed.

## Steps

### 1. Determine whether the current branch has an open PR

Start from the current branch:

```bash
git branch --show-current
```

Then check GitHub for an open PR on that branch:

```bash
gh pr view --json number,title,url,headRefName,baseRefName,state 2>/dev/null
```

If that fails or you need a fallback, use:

```bash
gh pr list --head "$(git branch --show-current)" --state open --json number,title,url,headRefName,baseRefName
```

Treat the branch as "has an open PR" only when GitHub returns an open PR for the current head branch.

### 2. Route to the correct workflow

If there is an open PR on the current branch:

1. Open `../triage-pr-comments/SKILL.md`.
2. Follow that skill exactly.
3. Do **not** run `macroscope codereview` in parallel or as a supplement.
4. Stop after triage and point the user to `../respond-to-pr-comments/SKILL.md` if they want you to act on the comments.

If there is no open PR on the current branch:

1. Open `../local-review/SKILL.md`.
2. Follow that skill exactly.
3. Keep the workflow closed-loop: triage streaming CLI findings, fix the valid ones, ignore false positives silently, and report only what you addressed.

### 3. Respect explicit user intent when it is narrower than `/macroscope:review`

- If the user explicitly asks to act on a previously triaged PR comment list, skip this router and use `../respond-to-pr-comments/SKILL.md`.
- If the user explicitly asks for a general review of the PR diff itself rather than comment triage, use `../review-pr/SKILL.md`.
