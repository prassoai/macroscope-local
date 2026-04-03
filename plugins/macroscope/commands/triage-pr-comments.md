---
name: triage-pr-comments
description: Internal PR comment triage worker for the router's PR path
---

Investigate every unresolved review comment on the current branch's PR. This is the PR path used by the top-level Macroscope router only when Macroscope correctness review has already run for the current local `HEAD`.

Present both valid and believed-invalid findings for the user to review. Do not resolve, comment on, or modify anything. This command is read-only.

These comments affect production code. A wrong dismissal lets a bug ship; a wrong acceptance wastes developer time. Verify claims against the actual code before forming a verdict.

Do not narrate your investigation or output reasoning during Steps 1 and 2. Only output the final triage format from Step 3.

## Steps

### 1. Fetch PR context

```bash
gh pr view --json number,title,url,headRefName,baseRefName
```

Extract `{owner}/{repo}` from the URL and note the base branch. Then fetch the diff, commit history, and review threads in parallel:

```bash
gh pr diff
```

```bash
git log --oneline origin/{baseRefName}..HEAD
```

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 100) {
              nodes {
                databaseId
                body
                path
                line
                author { login }
              }
            }
          }
        }
      }
    }
  }
' -f owner="{owner}" -f repo="{repo}" -F number={number}
```

Keep only threads where `isResolved` is `false`. Read the diff to understand what this PR changes. This context helps you investigate each comment.

### 2. Investigate and classify each comment

Read the relevant source files before forming any verdict. Base conclusions on the actual code, not just the diff hunk. Assume the reviewer is correct until you can concretely prove otherwise.

Group comments by file. Read each file once, then investigate all its comments before moving on. When tracing code paths, read multiple related files in parallel where possible.

For each comment:

1. Read the full file, not just the diff hunk, and check whether the code in question was changed in this PR.
2. Check how the surrounding codebase handles similar situations: architectural patterns, coding style, error handling conventions, and helper usage.
3. Trace the callers, callees, types, and interfaces the claim depends on.
4. Look for tests that exercise the code in question.
5. Verify external claims at the pinned dependency version when relevant.
6. Check whether a later commit on this PR already addressed the issue.
7. Form competing hypotheses for why the comment could be correct or incorrect.
8. Classify the comment:
   - **Valid** (default): identifies a real concern.
   - **Invalid** (requires proof): disproved with concrete, citable evidence from the codebase.
9. Re-read the original comment and the code one final time to verify the verdict.

When unsure, default to valid.

### 3. Present findings for review

Present findings in the following format. Do not use markdown headings (`##`, `###`). Use plain text with emoji markers for terminal readability.

**A) Summary header**

───────────────────────────────────────────────────────
🔍 PR Comment Triage: #{number} — {title}
{N} unresolved comments from {M} reviewers
✅ {x} believed valid | ❌ {y} believed invalid
───────────────────────────────────────────────────────

**B) Findings**

Present both categories so the user can confirm or adjust. Use a single global numbering sequence across both sections. For each item:

- Show `path:line`
- Show the reviewer handle inline
- Include a short excerpt of the original comment in *italics*
- Follow with a concise evidence line in backticks starting with `Confirmed —` or `Disproved —`
- Leave a blank line between items

**C) Reviewer breakdown**

Only include this if `--reviewer-stats` is in the arguments.

**D) Prompt for action**

Ask: "Do you want me to run `/respond-to-pr-comments` for the believed valid comments now?"
