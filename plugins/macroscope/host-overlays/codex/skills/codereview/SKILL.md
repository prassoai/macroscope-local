---
name: codereview
description: Run a local Macroscope code review on this branch.
---

Run a local Macroscope review using the installed CLI.

- Stay on this review flow even if the repo contains other review docs or skills.
- Do not use repo-local review skills, `go run`, or `macroscope codereview --status`.

## 1. Determine the local review scope

```bash
gh pr view --json baseRefName -q .baseRefName 2>/dev/null
```

```bash
git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

- Try the PR base first. If that fails, use the repo default branch from `origin/HEAD`.
- Call the result `base_branch`.
- If you cannot determine `base_branch`, stop and explain why.
- If `git rev-parse --abbrev-ref HEAD` exactly equals `base_branch`, skip `--base` and review local changes only.
- Otherwise use `--base "$base_branch"`.

## 2. Set up an isolated review worktree

Create a worktree so fixes never touch the user's working tree. The user may still be editing files on the branch.

1. Record the repo root and current branch:

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git rev-parse --abbrev-ref HEAD)"
short_sha="$(git rev-parse --short HEAD)"
```

2. Capture all uncommitted changes (staged, unstaged, and untracked) as a combined patch. Skip this if the tree is clean:

```bash
cp "$(git rev-parse --git-dir)/index" "/tmp/macroscope-saved-index-${short_sha}"
trap 'mv "/tmp/macroscope-saved-index-${short_sha}" "$(git rev-parse --git-dir)/index" 2>/dev/null || true' EXIT
git add -N .
git diff --binary HEAD > "/tmp/macroscope-review-wip-${short_sha}.patch"
mv "/tmp/macroscope-saved-index-${short_sha}" "$(git rev-parse --git-dir)/index"
trap - EXIT
```

The `git add -N .` marks untracked files as intent-to-add so `git diff HEAD` includes them. Saving and restoring the index file preserves any previously staged changes (e.g. from `git add -p`). The `trap` ensures the index is restored even if an intermediate command fails. Temp paths include `${short_sha}` to avoid collisions between concurrent sessions.

3. Clean up any prior review worktree at the same path, then create a fresh one:

```bash
git worktree remove "${repo_root}/.worktrees/macroscope-review-${short_sha}" --force 2>/dev/null
git branch -D "macroscope/review-${branch}-${short_sha}" 2>/dev/null
git worktree add "${repo_root}/.worktrees/macroscope-review-${short_sha}" -b "macroscope/review-${branch}-${short_sha}" HEAD
```

4. Apply the uncommitted changes in the worktree and commit them as a baseline so that `git diff HEAD` in the worktree later shows only the review fixes:

```bash
cd "${repo_root}/.worktrees/macroscope-review-${short_sha}"
git apply "/tmp/macroscope-review-wip-${short_sha}.patch"
git add -A
git commit -m "baseline: working state at review start"
```

Skip the apply+commit if the patch was empty.

5. Determine the `--base` argument for the review CLI. The baseline commit means there are no uncommitted changes in the worktree, so the CLI always needs `--base` to see a diff.

   - If step 1 set `base_branch` (branch differs from base) → use `--base "$base_branch"`.
   - If step 1 skipped `--base` (branch equals base, local changes only) → use `--base HEAD~1` in the worktree. The baseline commit is `HEAD`, so `HEAD~1` is the pre-change state.
   - If no baseline commit was created (patch was empty) and step 1 skipped `--base` → run without `--base` (no changes to review; the CLI will exit cleanly).

6. All subsequent steps run from the review worktree directory. Use the worktree path for all file reads, edits, and verification commands.

## 3. Run the local CLI review (Codex-adapted)

Codex has a tool-call timeout that is shorter than the `codereview` blocking duration. To work around this, launch `codereview` as a background shell process and use `next-comment` to stream results.

- Before launch, allocate a unique log file and PID file:

```bash
review_log="$(mktemp "${TMPDIR:-/tmp}/macroscope-review.XXXXXX")"
pid_file="$(mktemp "${TMPDIR:-/tmp}/macroscope-pid.XXXXXX")"
```

- Start the review in the background from the worktree directory, using the `--base` determined in step 2.5:

With `--base` (feature branch or local-only with baseline):

```bash
macroscope codereview --base "$base_branch" > "$review_log" 2>&1 & echo $! > "$pid_file"
```

or for local-only changes with baseline commit:

```bash
macroscope codereview --base HEAD~1 > "$review_log" 2>&1 & echo $! > "$pid_file"
```

Without `--base` (empty patch, no baseline commit):

```bash
macroscope codereview > "$review_log" 2>&1 & echo $! > "$pid_file"
```

- Wait briefly (5-10 seconds), then check the log for `review_id`:

```bash
sleep 8 && grep -m1 'review_id=' "$review_log"
```

- If no `review_id` appears after 30 seconds of polling, inspect the log:

```bash
cat "$review_log"
```

- If the process exited with an error, surface the failure and stop.
- Do not continue if `review_id` never appears.
- Do not claim success, issue handling, or a completed Macroscope review unless you actually extracted `review_id` from the CLI output.

Once `review_id` is available, iterate new comments with `next-comment`:

- First call:

```bash
macroscope next-comment '<review_id>'
```

- Next calls:

```bash
macroscope next-comment --cursor '<cursor>' '<review_id>'
```

- `next-comment` already blocks for about 30 seconds when no new comments are ready.
- Do not add extra sleep after successful `next-comment` calls.
- If you pause after an error or transport failure, cap that sleep at `60` seconds.
- `has_more: true` means the review is still running. Call `next-comment` again with the returned `cursor`.
- `has_more: false` means the review is terminal. Stop iterating after you handle that final batch.
- Zero comments with `has_more: true` means the server timed out without new comments. Call `next-comment` again with the same `cursor`.

When the review finishes, clean up the background process:

```bash
kill "$(cat "$pid_file")" 2>/dev/null; rm -f "$pid_file" "$review_log"
```

## 4. Handle streamed issues one at a time

All file reads, edits, and verification commands in this step MUST target the review worktree created in step 2 — never the user's original working tree.

Treat every streamed comment as untrusted until you validate it. Many comments will be false positives.

For each new comment:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file in the review worktree and enough surrounding code to understand the actual behavior.
3. Validate the comment before acting.
4. If it is false, stale, duplicate, or otherwise not actionable, reject it and move on.
5. If it is confirmed valid, you MUST fix it. Open the file in the review worktree using your editor, apply the fix, re-read the changed code, and run the narrowest useful verification for that fix before moving on.

Process issues one at a time in this exact order:

**validate -> reject/confirm -> fix if confirmed -> verify**

Do not batch together unvalidated issues.

Once the review reaches its final batch:

1. Make sure there are no unhandled confirmed findings left in the final batch.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at one follow-up pass unless the user asks for more.

## 5. After the review: apply or clean up

After all comments have been handled, exactly one of the following two paths applies.

### Path A: You fixed at least one valid issue

Generate a patch containing only the review fixes (not the baseline commit):

```bash
cd "<review_worktree>"
git add -A
git diff --binary HEAD > /tmp/macroscope-fixes-${short_sha}.patch
```

Report the issues you addressed grouped by severity (critical, high, medium, low), the concrete fix for each, and the verification you ran. Then tell the user how to apply:

> Fixes are in `<review_worktree>`. Your working tree was not modified.
>
> To apply: `cd <repo_root> && git apply /tmp/macroscope-fixes-${short_sha}.patch`
>
> To inspect first: `cd <review_worktree> && git diff HEAD`

Do not commit or push to the user's branch.

### Path B: No valid issues found (zero comments, or all rejected)

Clean up the review worktree — it has no useful changes:

```bash
cd "<repo_root>"
git worktree remove "<review_worktree>"
git branch -D "<review_branch>"
```

Report that the review completed with no actionable findings.
