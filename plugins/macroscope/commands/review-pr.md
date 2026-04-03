---
name: review-pr
description: Review a pull request for correctness, codebase patterns, and missing coverage
---

Review the code changes in a PR for correctness, codebase pattern adherence, idiomatic style, and test coverage. Present findings to the user and offer to fix them.

If a PR number is provided, review that PR. Otherwise, review the PR for the current branch.

A wrong finding wastes developer time; a missed issue lets a bug ship. Verify claims against the actual code before reporting.

## Steps

### 1. Understand the PR's intent

If a PR number was provided:

```bash
gh pr view {number} --json number,title,body,url,headRefName,baseRefName,commits
```

Otherwise:

```bash
gh pr view --json number,title,body,url,headRefName,baseRefName,commits
```

Extract `{owner}/{repo}` from the URL. Then fetch the diff:

```bash
gh pr diff {number}
```

Read the title, description, commit messages, and diff to understand what this PR is trying to accomplish.

### 2. Research existing codebase patterns

Before evaluating the changes, understand how the codebase already handles similar things. Read the files touched by the PR and their surrounding code to identify:

- Architectural and design patterns used in this area
- Coding style and conventions
- Error handling approach
- Helper usage
- How similar features or fixes were implemented elsewhere

This is the baseline you review against.

### 3. Check for bugs, pattern mismatches, and missing tests

For each potential issue:

1. Read the full file, not just the diff hunk.
2. Trace callers, callees, types, and interfaces until you can confirm the issue is real.
3. Verify library usage at the pinned dependency version when relevant.
4. Form competing hypotheses before reporting.
5. Re-read the code one final time and only report issues you can defend with concrete evidence.

### 4. Present findings

Output a concise self-contained list of issues:

```text
N issues found:

1. `path/to/file.go:42` - brief description of the issue and why it matters
2. `path/to/other.go:18` - brief description of the issue and why it matters
```

If no issues were found, say so.

Then offer to fix them. If the user agrees, fix each issue one at a time, verify each fix, then run the most relevant final test pass across the changed files before reporting back.
