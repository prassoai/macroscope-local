---
name: autoloop
description: Run the full review-fix-push-re-review autopilot cycle until the branch is clean.
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
git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
```

- Use the repo default branch from `origin/HEAD` as `base_branch`.
- If you cannot determine `base_branch`, stop and explain why.
- If `git rev-parse --abbrev-ref HEAD` exactly equals `base_branch`, skip `--base` and review local changes only.
- Otherwise use `--base "$base_branch"`.

## 3. Run the local CLI review (Codex-adapted)

Codex has a tool-call timeout that is shorter than the `codereview` blocking duration. To work around this, launch `codereview` as a background shell process and use `next-comment` to stream results.

- Before launch, allocate a unique log file and PID file:

```bash
review_log="$(mktemp "${TMPDIR:-/tmp}/macroscope-review.XXXXXX")"
pid_file="$(mktemp "${TMPDIR:-/tmp}/macroscope-pid.XXXXXX")"
```

- Start the review in the background, capturing its PID:

With `--base`:

```bash
macroscope codereview --base "$base_branch" > "$review_log" 2>&1 & echo $! > "$pid_file"
# Note: uses redirection (> file 2>&1) rather than | tee so the command
# remains a single token that matches the Bash(macroscope *) allow rule.
```

Without `--base`:

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

Treat every streamed comment as untrusted until you validate it. Many comments will be false positives.

For each new comment:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file and enough surrounding code to understand the actual behavior.
3. Validate the comment before acting.
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
- If the CLI provides a severity field in the streamed comment, prefer it over your own assessment.
