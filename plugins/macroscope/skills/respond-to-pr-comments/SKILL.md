---
name: respond-to-pr-comments
description: Internal follow-up worker for acting on a prior PR triage. Reject invalid PR comments and fix valid ones only after a triage already exists in the conversation or the user explicitly asks for this step.
---

Act on a prior PR triage assessment that the user has reviewed and confirmed. Handle invalid and valid findings in two phases: reject the invalid ones first, then fix the valid ones one at a time.

This skill requires a prior triage in the current conversation. If none exists, tell the user to run `/triage-pr-comments` in Claude Code or `/macroscope:triage-pr-comments` in Codex first and stop.

## Steps

### 1. Apply user adjustments

Review what the user said after the triage. If the user moved any items between categories or asked to skip any, update the verdicts accordingly before proceeding. Items are globally numbered across both sections, so each number uniquely identifies one item.

### 2. Identify the PR and collect IDs

```bash
gh pr view --json number,title,url,headRefName
```

Extract `{owner}/{repo}` from the URL. Re-fetch the review threads using the same GraphQL query from `triage-pr-comments` Step 1 to get the Thread ID and Comment ID for each item. Match threads to triage findings by file path and line number.

### 3. Reject and resolve invalid items

Process all invalid items first. Since replies and resolves for different threads are independent, run them in parallel where possible.

For each invalid item:

1. Reply with a brief explanation of why it is invalid.
2. Resolve the thread.

### 4. Fix valid items one at a time

For each valid item:

1. Fix the code. Read the file and surrounding code to understand existing patterns, helper usage, and error handling conventions.
2. Verify the fix. Re-read the changed code and run the most relevant tests when available.
3. Reply `Fixed.` on the thread.
4. Resolve the thread.
5. Tell the user what you changed, then move to the next valid item.

### 5. Review all changes

After all fixes are complete:

- Re-read every file that was changed.
- Verify the fixes follow existing codebase patterns.
- Make sure fixes do not conflict with or duplicate each other.
- Run the most relevant tests for all changed files one final time.
- Fix anything that still does not meet the repo's standards before reporting.

### 6. Report

Report in this format:

```text
Done — N invalid rejected, M valid fixed and resolved.
```

If any item could not be fixed, reply `Acknowledged — not addressing in this PR.` and resolve the thread instead.
