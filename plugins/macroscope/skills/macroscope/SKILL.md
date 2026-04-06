---
name: macroscope
description: Main Macroscope entrypoint. `/macroscope` runs the local CLI review path by default. `/macroscope loop` runs the full review-fix-push-re-review cycle until the branch is clean.
argument-hint: [loop]
---

Default mode:

- With no arguments, start with the local streaming CLI review path.
- Keep the flow closed-loop: validate each streamed issue, reject false positives, fix confirmed issues, and report only what you addressed.
- Stay on this workflow even if the repo contains other review docs or skills.
- Do not switch to repo-local review instructions such as `.claude/skills/local-review/SKILL.md`.
- Use the installed `macroscope` CLI here, not `go run ./tools/cmd/macrodaemon`.

`loop` mode:

- If the first argument is `loop`, keep iterating through local review, push, remote correctness review, and PR-comment handling until there is nothing left to address or you hit a hard stop.

## Steps

### 1. Parse the invocation mode

- If it is exactly `loop`, run the autopilot flow from Step 6.
- Otherwise, run the default local CLI review flow from Steps 2 through 5.

### 2. Detect the local review scope

```bash
git merge-base --is-ancestor HEAD origin/staging && echo "ON_STAGING" || echo "FEATURE_BRANCH"
```

- If `ON_STAGING`: skip `--base` and review uncommitted changes only.
- If `FEATURE_BRANCH`: use `--base staging`.

### 3. Move the streaming review into a sub-agent when the host supports it

- If the host supports sub-agents, delegated workers, or background agents, open one here.
- That worker owns the full review lifecycle:

**start review -> extract review_id -> poll -> narrate -> validate -> reject/confirm -> fix -> verify**

- Keep the primary agent free for concise user-facing progress updates and final coordination.
- If the host does not support sub-agents, keep the entire workflow attached in the current agent instead of detaching it.

### 4. Run the local CLI review

- `codereview` is blocking. Keep it in an attached session for the full lifetime of the review.
- Never use `nohup`, shell `&`, or any detached background process that can lose the tool-call loop.
- Before launch, allocate a unique log file for this run so concurrent sessions do not clobber one another:

```bash
review_log="$(mktemp "${TMPDIR:-/tmp}/macroscope-review.XXXXXX")"
```

- Start the review:

```bash
macroscope codereview --base <base_branch> 2>&1 | tee "$review_log"
```

- Wait for the review to emit a `review_id`, then extract it:

```bash
grep -m1 'review_id=' "$review_log"
```

- If no `review_id` appears after a reasonable wait, inspect the log, surface the failure, and stop.
- While the review runs, poll for incremental results:

```bash
macroscope codereview --status '<review_id>' 2>&1
```

- Each status payload can contain a current issue set plus `poll_after_seconds`.
- Clamp every sleep:

- `sleep_seconds = min(max(poll_after_seconds, 1), 60)`
- Never sleep longer than `60` seconds.
- Never compound the sleep across cycles.

- Maintain a seen-set of issue fingerprints so you only process newly surfaced findings on each poll. Use a stable fingerprint such as:

`file:start_line:end_line:category:message`

### 5. Handle streamed issues one at a time

As each new issue arrives:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file and enough surrounding code to understand the actual behavior.
3. Validate the issue before acting.
4. Classify it as either:
   - **Rejected**: false positive, stale, duplicate, or otherwise not a real issue
   - **Confirmed**: legitimate bug, regression, or correctness problem that should be fixed
5. If the issue is rejected, mark it handled and continue without including it in the final summary.
6. If the issue is confirmed, fix it immediately in the working tree.
7. Run the narrowest useful verification for that fix before moving on.

Process issues one at a time in this exact order:

**validate -> reject/confirm -> fix if confirmed -> verify**

Do not batch together unvalidated issues.

Once the review reaches its final snapshot:

1. Make sure there are no unhandled confirmed findings left in the final payload.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at one follow-up pass unless the user asks for more.
4. Let the attached `codereview` process exit naturally. If it is still alive after the final snapshot and you no longer need it, stop it cleanly.

When you report back in the default mode:

- List only the issues you actually addressed.
- Summarize the concrete fix for each addressed issue.
- Include the verification you ran.
- Omit rejected findings and findings you took no action on.

Do not commit or push in the default mode.

### 6. `loop` mode: full autopilot

In `loop` mode, run the full cycle:

**local review -> fix -> verify -> commit -> push -> wait for correctness check -> handle PR comments -> repeat**

This mode is allowed to commit and push.

At the start of `loop` mode:

1. Capture the current branch name and `HEAD`.
2. Determine whether the branch has an open PR:

```bash
gh pr view --json number,title,url,headRefOid,statusCheckRollup 2>/dev/null
```

3. Keep an iteration counter and cap the loop at **5** iterations.

Each iteration starts with the local CLI review flow from Steps 2 through 5.

If the local review changed code:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.
3. Push the branch.
4. Refresh the current `HEAD`.

After every push, wait for the current `HEAD` to receive a successful Macroscope correctness review before acting on PR comments.

Poll:

```bash
gh pr view --json number,title,url,headRefOid,statusCheckRollup 2>/dev/null
```

Treat the check as ready only when all of these are true:

1. `gh pr view` succeeds.
2. `headRefOid` exactly matches the current local `HEAD`.
3. `statusCheckRollup` contains a check run named `Macroscope - Correctness Check`.
   For compatibility, also accept `Review for correctness`.
4. That check has `status == "COMPLETED"`, `conclusion == "SUCCESS"`, and a non-null `completedAt`.

Once the current `HEAD` has a successful correctness review:

1. Fetch unresolved review threads on the PR.
2. Focus on comments attributable to the Macroscope correctness review for the current `HEAD`.
3. Validate each unresolved comment before acting.
4. If a comment is invalid, reply briefly, reject it, and resolve the thread.
5. If a comment is valid, fix it, verify the fix, reply with what changed, and resolve the thread.

If PR-comment handling changes code:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.
3. Push the branch.
4. Continue to the next iteration so the new `HEAD` gets reviewed.

Stop the loop when all of the following are true in the same iteration:

1. The local CLI review phase did not change code.
2. The PR-comment handling phase did not change code.
3. The current local `HEAD` already has a successful Macroscope correctness review.
4. There are no unresolved confirmed Macroscope comments left to address for that `HEAD`.

When the loop stops, summarize the issues you addressed, the commits you pushed, and the verification you ran.
