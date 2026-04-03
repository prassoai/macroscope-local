---
name: macroscope
description: Primary entrypoint for this plugin. Use this whenever the user says "macroscope", asks to "use macroscope", or asks to review a branch with Macroscope. First check whether correctness review already ran for the current local HEAD. If it did, triage unresolved PR comments. If it did not, run the local CLI review, fix valid findings, and report what was addressed.
---

Use this as the canonical Macroscope router.

If the user mentions `macroscope` at all, start here unless they are explicitly asking for one of the narrower follow-up workers by name.

In Claude Code, this skill is `/macroscope`.

In Codex, plugin skills are namespaced, so this skill is `/macroscope:macroscope`.

This skill chooses between two different workflows:

- **PR path**: Macroscope correctness review already ran for the current local `HEAD`. Use the PR-comment path only then. Do **not** run the Macroscope CLI.
- **CLI path**: Macroscope correctness review has not run for the current local `HEAD`. Use the local CLI path.

## Steps

### 1. Check whether Macroscope correctness review already ran for the current local HEAD

Start from the current local HEAD:

```bash
LOCAL_HEAD="$(git rev-parse HEAD)"
```

Then ask GitHub for the PR associated with the current branch and its status checks:

```bash
gh pr view --json number,title,url,headRefOid,statusCheckRollup 2>/dev/null
```

Treat Macroscope correctness review as having already run for the current local `HEAD` only when both of these are true:

1. `gh pr view` succeeds and `headRefOid` exactly matches `LOCAL_HEAD`.
2. `statusCheckRollup` contains a successful GitHub check run named `Macroscope - Correctness Check`.
   For compatibility, also accept the legacy name `Review for correctness`.
   The matching check should have `status == "COMPLETED"`, `conclusion == "SUCCESS"`, and a non-null `completedAt`.

If either condition fails, use the CLI path.

### 2. Route to the correct workflow

If Macroscope correctness review already ran for the current local `HEAD`:

1. Open `../triage-pr-comments/SKILL.md`.
2. Follow that skill exactly.
3. Do **not** run `macroscope codereview` in parallel or as a supplement.
4. Stop after triage and point the user to `../respond-to-pr-comments/SKILL.md` if they want you to act on the comments.

If Macroscope correctness review has not run for the current local `HEAD`:

1. Open `../local-review/SKILL.md`.
2. Follow that skill exactly.
3. Keep the workflow closed-loop: triage streaming CLI findings, fix the valid ones, ignore false positives silently, and report only what you addressed.

### 3. Respect explicit user intent when it is narrower than the top-level Macroscope router

- If the user explicitly asks to act on a previously triaged PR comment list, skip this router and use `../respond-to-pr-comments/SKILL.md`.
- If the user explicitly asks for a general review of the PR diff itself rather than comment triage, use `../review-pr/SKILL.md`.
