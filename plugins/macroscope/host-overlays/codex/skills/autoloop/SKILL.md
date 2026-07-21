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
if [ -z "$base_branch" ]; then
  # No origin/HEAD (e.g. a repo without an origin remote): fall back to a local default branch.
  for candidate in "$(git config --get init.defaultBranch)" main master; do
    [ -n "$candidate" ] && git rev-parse --verify --quiet "refs/heads/${candidate}^{commit}" >/dev/null && { base_branch="$candidate"; break; }
  done
fi
```

- Use the resulting `base_branch` as the comparison branch.
- If you cannot determine `base_branch`, stop and explain why.
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

## 3. Run the local CLI review (Codex-adapted)

Codex has a tool-call timeout that is shorter than the `codereview` blocking duration. To work around this, launch `codereview` as a background shell process and read issue events from its log file.

- Before launch, allocate a unique log file and PID file:

```bash
review_log="$(mktemp "${TMPDIR:-/tmp}/macroscope-review.XXXXXX")"
pid_file="$(mktemp "${TMPDIR:-/tmp}/macroscope-pid.XXXXXX")"
```

- Start the review in the background. Capture the child PID, then wait for it in the same shell so the process stays attached while later tool calls poll the log:

With `--base`:

```bash
macroscope codereview --raw --base "$base_ref" > "$review_log" 2>&1 &
child_pid=$!
printf '%s\n' "$child_pid" > "$pid_file"
wait "$child_pid"
```

Without `--base`:

```bash
macroscope codereview > "$review_log" 2>&1 &
child_pid=$!
printf '%s\n' "$child_pid" > "$pid_file"
wait "$child_pid"
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

Issues stream directly from the `codereview` process into the log file as `issue_event=<json>` lines. Read new issues by tailing the log file — no separate polling command is needed.

- Each `issue_event=` line contains a JSON object:
  ```
  issue_event={"issue_id":"...","sequence":1,"path":"file.go","line":42,"severity":"medium","category":"REVIEW_TYPE_CORRECTNESS","body":"..."}
  ```
- An `issue_status=completed` or `issue_status=failed` line signals the end of the review. Stop reading after you see it.
- To incrementally read only new lines, track the line count and use `tail -n +<next_line>`:

```bash
tail -n +"$last_line" "$review_log" | grep 'issue_event=\|issue_status='
```

- Continue reading the log for new `issue_event=` lines until the terminal status appears or the background process exits.

When the review finishes, clean up the background process:

```bash
kill "$(cat "$pid_file")" 2>/dev/null || true
unlink "$pid_file" 2>/dev/null || true
unlink "$review_log" 2>/dev/null || true
```

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
