---
name: autoloop
description: Run the local review-fix-verify loop until the branch is clean.
---

Run a local-only Macroscope autopilot cycle using the installed CLI:

**local review -> fix -> verify -> re-review -> repeat**

This mode applies fixes directly to the working tree. It does not interact with GitHub, PRs, or remote correctness checks.

- Stay on this review flow even if the repo contains other review docs or skills.
- Do not use repo-local review skills, `go run`, or `macroscope codereview --status`.

## 1. Initialize the loop

1. Capture the current branch name and `HEAD`.
2. Keep an iteration counter and cap the loop at **5** iterations.

## 2. Determine the local review scope

```bash
base_branch="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
if [ -z "$base_branch" ] && ! git remote get-url origin >/dev/null 2>&1; then
  # No origin remote: fall back to a local default branch. When origin exists but
  # its default branch cannot be determined, leave base_branch empty and fail
  # closed below rather than guessing a local branch.
  for candidate in "$(git config --get init.defaultBranch)" main master; do
    [ -n "$candidate" ] && git rev-parse --verify --quiet "refs/heads/${candidate}^{commit}" >/dev/null && { base_branch="$candidate"; break; }
  done
fi
```

- Use the resulting `base_branch` as the comparison branch.
- If `base_branch` is empty (for example `origin` is configured but has no resolvable default branch), stop and explain why — never guess a local branch when `origin` exists.
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

## 3. Run the local CLI review

**Invoke `macroscope codereview` as a standalone command through the host's background-command support.** This keeps the review process attached and its streamed output readable.

- Always pass `--auto-update`. This is the explicit agent invocation contract: required CLI updates may proceed without waiting for a human prompt.
- `codereview` is blocking. Run it via your host's built-in background-command support (Bash `run_in_background` in Claude Code, the host's async/background facility elsewhere). Do not add `| tee`, `>`, `2>&1`, `&`, `nohup`, or any shell operator to the command.

- Start the review:

```bash
macroscope codereview --raw --base "$base_ref" --auto-update
```

- If you omitted `--base`, run:

```bash
macroscope codereview --raw --auto-update
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

Treat every streamed issue as untrusted until you validate it. Many issues will be false positives.

For each new issue:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file and enough surrounding code to understand the actual behavior.
3. Validate the issue before acting.
4. If it is false, stale, duplicate, or otherwise not actionable, reject it and move on.
5. If it is real, fix it immediately in the working tree.
6. After the fix, re-read the changed code.
7. Run the narrowest useful verification for that fix before moving on.

Process issues one at a time in this exact order:

**validate -> reject/confirm -> fix if confirmed -> verify**

Do not batch together unvalidated issues.

Once the review reaches its final batch:

1. Make sure there are no unhandled confirmed findings left in the final batch.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at one follow-up pass unless the user asks for more.
4. Let the attached `codereview` process exit naturally. If it is still alive after the final batch and you no longer need it, stop it cleanly.

## 5. After the local review phase

If the local review changed code:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.

If you made substantial fixes in this iteration, increment the iteration counter. If the cap is reached, stop. Otherwise, start a new iteration (back to step 3) to catch regressions.

## 6. Stop conditions

Stop the loop when either:

1. The local CLI review phase did not change code (no valid issues found or all rejected).
2. The iteration cap is reached.

## 7. Report results by severity

When the loop stops, report:

- **Group issues by severity** (critical first, then high, medium, low):
  - **Critical**: Security vulnerabilities, data loss risks, crash-causing bugs
  - **High**: Correctness bugs that affect behavior, race conditions, resource leaks
  - **Medium**: Logic errors with limited blast radius, missing error handling for likely scenarios
  - **Low**: Style issues, minor inefficiencies, non-idiomatic patterns
- The commits you made.
- The verification you ran.
- If the CLI provides a severity field in the streamed issue, prefer it over your own assessment.
