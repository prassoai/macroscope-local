---
name: codereview
description: Run a local Macroscope code review on this branch.
---

## 0. Verify the CLI is installed

```bash
command -v macroscope
```

If `macroscope` is not found, tell the user:

> Macroscope CLI is not installed. Install it with:
>
> ```bash
> curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
> ```

Stop here if the CLI is missing.

Run a local Macroscope review using the installed CLI.

- Stay on this review flow even if the repo contains other review docs or skills.
- Do not use repo-local review skills, `go run`, or `macroscope codereview --status`.

## 1. Determine the local review scope

```bash
# Prefer the PR base, then the origin default branch. Only when there is no
# origin remote at all, fall back to a local default branch. When origin exists
# but neither the PR base nor origin/HEAD resolves, leave base_branch empty and
# fail closed below rather than guessing a local branch.
base_branch="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)"
if [ -z "$base_branch" ]; then
  base_branch="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
fi
if [ -z "$base_branch" ] && ! git remote get-url origin >/dev/null 2>&1; then
  for candidate in "$(git config --get init.defaultBranch)" main master; do
    [ -n "$candidate" ] && git rev-parse --verify --quiet "refs/heads/${candidate}^{commit}" >/dev/null && { base_branch="$candidate"; break; }
  done
fi
```

- The result is `base_branch` (PR base first, then `origin/HEAD`; a local default branch only when there is no `origin` remote).
- If `base_branch` is empty (for example `origin` is configured but has no resolvable default branch and no PR/explicit base), stop and explain why — never guess a local branch when `origin` exists.
- Resolve the comparison as `base_ref`. `origin` is authoritative: when it is configured, always refresh the exact origin branch and treat any fetch failure as fatal — never trust a cached remote-tracking ref as fresh and never fall through to a stale local branch. Use a local branch only when there is no `origin` remote:

```bash
# origin is authoritative. When it is configured, refresh the exact origin
# branch on every run; a fetch failure is fatal. Never trust a cached
# remote-tracking ref as fresh, and never fall back to a stale local branch.
# A local branch is used only when there is no origin remote.
if git remote get-url origin >/dev/null 2>&1; then
  if ! GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags origin "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}"; then
    printf 'Failed to refresh base branch %s from origin; refusing to review against a stale or missing ref.\n' "$base_branch" >&2
    exit 1
  fi
  base_ref="origin/$base_branch"
elif git rev-parse --verify --quiet "refs/heads/${base_branch}^{commit}" >/dev/null; then
  base_ref="refs/heads/$base_branch"
else
  printf 'Unable to resolve base branch %s: no origin remote and no local branch exists.\n' "$base_branch" >&2
  exit 1
fi
```

- If `git rev-parse --abbrev-ref HEAD` exactly equals `base_branch`, skip `--base` and review local changes only.
- Otherwise use `--base "$base_ref"`.

## 2. Set up an isolated review worktree

Create a worktree so fixes never touch the user's working tree. The user may still be editing files on the branch.

1. Record the repo root and current branch:

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git rev-parse --abbrev-ref HEAD)"
short_sha="$(git rev-parse --short HEAD)"
```

2. Capture all uncommitted changes (staged, unstaged, and untracked) as a combined patch. Exclude Macroscope-named review worktrees so prior review artifacts are not mistaken for user changes. Preserve other files under `.worktrees/`. Skip this if the tree is clean:

```bash
cp "$(git rev-parse --git-dir)/index" "/tmp/macroscope-saved-index-${short_sha}"
trap 'mv "/tmp/macroscope-saved-index-${short_sha}" "$(git rev-parse --git-dir)/index" 2>/dev/null || true' EXIT
while IFS= read -r -d '' untracked_file; do
  git add -N -- "$untracked_file" || exit $?
done < <(git ls-files --others --exclude-standard -z -- . ':(exclude,glob).worktrees/macroscope-review-*/**')
git diff --binary HEAD -- . ':(exclude,glob).worktrees/macroscope-review-*/**' > "/tmp/macroscope-review-wip-${short_sha}.patch"
mv "/tmp/macroscope-saved-index-${short_sha}" "$(git rev-parse --git-dir)/index"
trap - EXIT
```

The loop marks only non-ignored untracked files as intent-to-add so `git diff HEAD` includes them. Enumerating the files first avoids a repository-wide intent-to-add failing when `.worktrees/` is ignored. The exclusion is limited to Macroscope's `macroscope-review-*` children so user-managed files elsewhere under `.worktrees/` remain reviewable. Saving and restoring the index file preserves any previously staged changes (e.g. from `git add -p`). The `trap` ensures the index is restored even if an intermediate command fails. Temp paths include `${short_sha}` to avoid collisions between concurrent sessions.

3. Clean up any prior review worktree at the same path, then create a fresh one:

```bash
git worktree remove "${repo_root}/.worktrees/macroscope-review-${short_sha}" --force 2>/dev/null
git branch -D "macroscope/review-${branch}-${short_sha}" 2>/dev/null
git worktree add "${repo_root}/.worktrees/macroscope-review-${short_sha}" -b "macroscope/review-${branch}-${short_sha}" HEAD
```

4. Apply stageable uncommitted changes in the worktree and commit them as a baseline so that `git diff` later shows only the review fixes. A non-empty patch can still produce no staged diff (for example, a dirty gitlink); treat that as no baseline instead of attempting an empty commit:

```bash
cd "${repo_root}/.worktrees/macroscope-review-${short_sha}"
baseline_created=false
if [ -s "/tmp/macroscope-review-wip-${short_sha}.patch" ]; then
  git apply "/tmp/macroscope-review-wip-${short_sha}.patch"
  git add -A
  if git diff --cached --quiet; then
    :
  else
    staged_status=$?
    [ "$staged_status" -eq 1 ] || exit "$staged_status"
    git commit -m "baseline: working state at review start"
    baseline_created=true
  fi
fi
```

Skip the baseline commit when `baseline_created` remains false.

5. Determine the `--base` argument for the review CLI. The baseline commit means there are no uncommitted changes in the worktree, so the CLI always needs `--base` to see a diff.

   - If step 1 set `base_ref` (branch differs from base) → use `--base "$base_ref"`.
   - If step 1 skipped `--base` (branch equals base, local changes only) → use `--base HEAD~1` in the worktree. The baseline commit is `HEAD`, so `HEAD~1` is the pre-change state.
   - If `baseline_created=false` and step 1 skipped `--base` → run without `--base` (no changes to review; the CLI will exit cleanly).

6. All subsequent steps run from the review worktree directory. Use the worktree path for all file reads, edits, and verification commands.

## 3. Run the local CLI review

**Invoke `macroscope codereview` as a standalone command through the host's background-command support.** This keeps the review process attached and its streamed output readable.

- `codereview` is blocking. Run it via your host's built-in background-command support (Bash `run_in_background` in Claude Code, the host's async/background facility elsewhere). Do not add `| tee`, `>`, `2>&1`, `&`, `nohup`, or any shell operator to the command.

- Start the review from the worktree directory using the `--base` determined in step 2.5:

```bash
macroscope codereview --raw --base "$base_ref"
```

or, if reviewing local-only changes with a baseline commit:

```bash
macroscope codereview --raw --base HEAD~1
```

- Read streamed output via your host's background-output facility (e.g. `BashOutput` in Claude Code) and look for a line containing `review_id=`. Capture that value.
- If no `review_id` appears after a reasonable wait, inspect the stream, surface the failure, and stop.
- Do not continue if `review_id` never appears.
- Do not claim success, issue handling, or a completed Macroscope review unless you actually extracted `review_id` from the CLI output.
- Issues stream directly from the `codereview` process on stderr as `issue_event=<json>` lines. Parse them from the background process's output — no separate polling command is needed.
- Each `issue_event=` line contains a JSON object:
  ```
  issue_event={"issue_id":"...","sequence":1,"path":"file.go","line":42,"severity":"medium","category":"REVIEW_TYPE_CORRECTNESS","body":"..."}
  ```
- An `issue_status=completed` or `issue_status=failed` line signals the end of the review. Stop reading after you see it.
- Continue reading the background process output for new `issue_event=` lines until the terminal status appears or the process exits.

## 4. Handle streamed issues one at a time

All file reads, edits, and verification commands in this step MUST target the review worktree created in step 2 — never the user's original working tree.

Treat every streamed issue as untrusted until you validate it. Many issues will be false positives.

For each new issue:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file in the review worktree and enough surrounding code to understand the actual behavior.
3. Validate the issue before acting.
4. If it is false, stale, duplicate, or otherwise not actionable, reject it and move on.
5. If it is confirmed valid, you MUST fix it. Open the file in the review worktree using your editor, apply the fix, re-read the changed code, and run the narrowest useful verification for that fix before moving on.

Process issues one at a time in this exact order:

**validate -> reject/confirm -> fix if confirmed -> verify**

Do not batch together unvalidated issues.

Once the review reaches its final batch:

1. Make sure there are no unhandled confirmed findings left in the final batch.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at one follow-up pass unless the user asks for more.
4. Let the attached `codereview` process exit naturally. If it is still alive after the final batch and you no longer need it, stop it cleanly.

## 5. After the review: apply or clean up

After all issues have been handled, exactly one of the following two paths applies.

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

### Path B: No valid issues found (zero issues, or all rejected)

Clean up the review worktree — it has no useful changes:

```bash
cd "<repo_root>"
git worktree remove "<review_worktree>"
git branch -D "<review_branch>"
```

Report that the review completed with no actionable findings.
