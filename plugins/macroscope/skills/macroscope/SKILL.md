---
name: macroscope
description: Main Macroscope entrypoint. If the current branch has an open or draft PR whose HEAD commit already has a completed Macroscope correctness check, triage unresolved PR comments. Otherwise run a local Macroscope review, triage streaming findings, fix the valid ones, and report what was addressed.
---

Use this as the canonical Macroscope router.

In Claude Code, this skill is `/macroscope`.

In Codex, plugin skills are namespaced, so this skill is `/macroscope:macroscope`.

This skill chooses between two different workflows:

- **Eligible PR-backed review**: the current branch has an open or draft PR, the PR `headRefOid` matches local `HEAD`, and that PR head already has a completed `Macroscope - Correctness Check` run. Use the PR-comment path only then. Do **not** run the Macroscope CLI.
- **Everything else**: use the local CLI path only. This includes no PR yet, a draft/open PR whose head is behind local `HEAD`, and a PR whose Macroscope correctness check has not run or has not finished yet.

## Steps

### 1. Determine whether the current branch has an eligible PR-backed review

Start from the current branch and local HEAD:

```bash
CURRENT_BRANCH="$(git branch --show-current)"
LOCAL_HEAD="$(git rev-parse HEAD)"
```

Then look for an open or draft PR whose head branch matches `CURRENT_BRANCH`:

```bash
gh pr list --head "$CURRENT_BRANCH" --state open --json number,title,url,headRefName
```

If that returns a PR for the current branch, fetch the full PR metadata including the head SHA and status checks:

```bash
gh pr view <number> --json number,title,url,headRefName,baseRefName,state,isDraft,headRefOid,statusCheckRollup
```

Treat the branch as having an **eligible PR-backed review** only when all of the following are true:

1. The PR is open (`state == "OPEN"`). Draft PRs count here too; they are still open PRs.
2. `headRefName` exactly matches `CURRENT_BRANCH`.
3. `headRefOid` exactly matches `LOCAL_HEAD`. If local `HEAD` is ahead of the PR, the PR check is stale for this run.
4. `statusCheckRollup` contains a completed GitHub check run named `Macroscope - Correctness Check`.
   For compatibility, also accept the legacy name `Review for correctness`.
5. The matching correctness check has `status == "COMPLETED"` and a non-null `completedAt`.

If any of those conditions fail, route to the local CLI path.

### 2. Route to the correct workflow

If there is an eligible PR-backed review:

1. Open `../triage-pr-comments/SKILL.md`.
2. Follow that skill exactly.
3. Do **not** run `macroscope codereview` in parallel or as a supplement.
4. Stop after triage and point the user to `../respond-to-pr-comments/SKILL.md` if they want you to act on the comments.

If there is no eligible PR-backed review:

1. Open `../local-review/SKILL.md`.
2. Follow that skill exactly.
3. Keep the workflow closed-loop: triage streaming CLI findings, fix the valid ones, ignore false positives silently, and report only what you addressed.
4. Do this even if the branch already has an open or draft PR, when the PR head is stale relative to local `HEAD`, or when the Macroscope correctness check is missing or still in progress.

### 3. Respect explicit user intent when it is narrower than the top-level Macroscope router

- If the user explicitly asks to act on a previously triaged PR comment list, skip this router and use `../respond-to-pr-comments/SKILL.md`.
- If the user explicitly asks for a general review of the PR diff itself rather than comment triage, use `../review-pr/SKILL.md`.
