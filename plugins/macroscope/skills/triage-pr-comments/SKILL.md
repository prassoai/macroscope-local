---
name: triage-pr-comments
description: Investigates unresolved PR review comments on the current branch's PR and presents findings for user review. Does not take any action. Use --reviewer-stats to include per-reviewer hit rates.
---

Investigate every unresolved review comment on the current branch's PR. This is the PR path used by `/macroscope:review` when the branch already has an open PR.

Present both valid and believed-invalid findings for the user to review. Do not resolve, comment on, or modify anything. This skill is read-only.

<accuracy_priority>
These comments affect production code. A wrong dismissal lets a bug ship; a wrong acceptance wastes developer time. Verify claims against the actual code before forming a verdict.
</accuracy_priority>

<output_behavior>
Do not narrate your investigation or output reasoning during Steps 1 and 2. Only output the final triage format from Step 3.
</output_behavior>

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

<investigate_before_judging>
Read the relevant source files before forming any verdict. Base conclusions on the actual code, not just the diff hunk. Assume the reviewer is correct until you can concretely prove otherwise.
</investigate_before_judging>

Group comments by file. Read each file once, then investigate all its comments before moving on. When tracing code paths, read multiple related files in parallel where possible.

For each comment:

<investigation_steps>

**a) Read the code.** Open the full file, not just the diff hunk. Check the diff to understand whether the code in question was changed in this PR or already existed.

**b) Understand codebase patterns.** Check how the surrounding codebase handles similar situations: architectural patterns, coding style, error handling conventions, helper usage. Patterns are evidence in both directions.

**c) Trace the code paths the claim depends on.** Follow callers, callees, types, and interfaces until you can confirm or rule out the scenario the comment describes.

**d) Check tests.** Look for tests that exercise the code in question. A passing test covering the exact scenario is strong evidence for "invalid". Absence of tests is not evidence either way.

**e) Verify external claims at the pinned version.** Check the dependency manifest for the version, then verify against the actual library source, docs, or web search if needed.

**f) Check if already addressed.** If a later commit on this PR already fixed the issue, classify as "invalid" and cite the commit.

**g) Form competing hypotheses.** Explicitly consider both directions before deciding:
- "What evidence supports this comment being correct?"
- "What evidence supports this comment being incorrect?"

**h) Classify.** Apply one of these verdicts:
- **Valid** (default): identifies a real concern.
- **Invalid** (requires proof): disproved with concrete, citable evidence from the codebase.

**i) Verify your verdict.** Re-read the original comment and the code one final time. Confirm you investigated the exact claim the reviewer made, not something adjacent.

</investigation_steps>

<verdict_examples>

Strong "invalid":
> "resp can be nil here" — You traced all callers, confirmed each returns non-nil on nil error, and cited the call sites by file and line.

Insufficient "invalid":
> "resp can be nil here" — You read the function but did not trace the callers.

When unsure, default to valid:
> "potential race condition on this map" — Concurrent access looks possible but you could not fully trace the locking. Mark valid.

</verdict_examples>

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

Ask: "Do you want me to run `/macroscope:respond-to-pr-comments` for the believed valid comments now?"
