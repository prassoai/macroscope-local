---
name: macroscope-local-review
description: Explicit local Macroscope CLI review worker. Use this when the user explicitly asks for the local path, or when `/macroscope` delegates here.
---

Run a code review using the installed `macroscope` CLI, then triage streaming issues as they arrive. This is the default workflow behind `/macroscope`.

This workflow is **closed-loop**:

- Treat raw pipeline issues as untrusted input until you verify them.
- Investigate each streamed issue against the actual code.
- Ignore false positives silently.
- Fix valid findings immediately in the working tree.
- Run targeted verification for the fixes you make.
- Report only the issues you addressed.

Do **not** stop after triage to ask for confirmation. Do **not** commit or push.

## Steps

### 0. Detect the base branch

Auto-detect whether you're on a feature branch so the review covers all changes (committed + uncommitted):

```bash
git merge-base --is-ancestor HEAD origin/staging && echo "ON_STAGING" || echo "FEATURE_BRANCH"
```

- If `ON_STAGING`: skip `--base` and review uncommitted changes only.
- If `FEATURE_BRANCH`: use `--base staging`.

### 1. Start the blocking review in an attached session

The `codereview` command is **blocking**. It maintains an agent loop for tool calls and a watch stream for progress until the review completes.

Do **not** use `nohup`, shell `&`, or any other detached background process here. A detached process can lose the tool-call loop and make the review fail silently.

Preferred execution model:

- If the host supports sub-agents, background agents, or delegated tasks, give one attached worker ownership of the blocking `macroscope codereview` process.
- If the host does not support sub-agents, keep the blocking review in one attached long-lived shell or PTY session and use separate attached shell calls for `--status` polling.

Before you launch the review, allocate a unique log file for this run so concurrent Macroscope sessions do not clobber each other:

```bash
review_log="$(mktemp /tmp/macroscope-review.XXXXXX.log)"
```

Example attached launch:

```bash
macroscope codereview --base <base_branch> 2>&1 | tee "$review_log"
```

Keep that attached review session alive while you poll. It is servicing the remote review agent's tool calls.

### 2. Extract the review ID

Wait for the build/upload/start phase to complete, then extract the `review_id` from the attached review output:

```bash
grep -m1 'review_id=' "$review_log"
```

Save this JWT. You need it for polling partial results.

If no `review_id` appears after a reasonable wait, inspect `"$review_log"`, surface the failure, and stop.

### 3. Move the polling loop into a sub-agent when the host supports it

If your host supports sub-agents, background agents, or delegated tasks, use one here.

That worker owns the full:

**poll -> narrate -> validate -> fix -> verify**

loop after the `review_id` is available, and it should keep the blocking `codereview` process attached for the lifetime of the review.

Keep the primary agent free for concise user-facing progress updates and final coordination.

If the host does not support sub-agents, continue in the current agent without detaching the blocking review process.

### 4. Poll for partial results

While the attached review process runs, poll for incremental results:

```bash
macroscope codereview --status '<review_id>' 2>&1
```

This returns the current status snapshot:

```json
{
  "status": "in_progress|completed|failed",
  "issues": [...],
  "poll_after_seconds": 5,
  "is_final": false
}
```

- If `is_final` is false, keep polling and wait `poll_after_seconds` between polls.
- If `is_final` is true, the review is done and all issues are final.
- Each poll returns the **current** set of issues.

Clamp the sleep each time:

- `sleep_seconds = min(max(poll_after_seconds, 1), 60)`
- Never increase the sleep above `60` seconds.
- Never compound sleeps across poll cycles.

Maintain a seen-set of issue fingerprints so you only process newly surfaced findings on each poll. Use a stable fingerprint such as:

`file:start_line:end_line:category:message`

### 5. Triage and fix issues as they arrive

Don't wait for the review to finish. As soon as issues appear in a poll response, start triaging and fixing new findings.

<triage_rules>
For each issue, read the affected file and evaluate whether the finding is legitimate. Classify each as:

- **Valid**: The issue is real and should be fixed.
- **False positive**: The reviewer misunderstood the code or the issue was already addressed elsewhere.
</triage_rules>

Assume many streamed issues will be false positives until you validate them against the actual code.

For each **new** finding:

1. Narrate the issue as it arrives with a concrete one-line summary.
   Example: `First issue arrived - the check-completed heuristic doesn't consider the check conclusion.`
   Do **not** use vague updates like `first issue found`.
2. Read the relevant file and surrounding code, not just the cited lines.
3. Check the existing codebase patterns and trace the code paths the claim depends on.
4. Look for signs the issue is already fixed locally, already handled by later edits, or is otherwise a false positive.
5. Group duplicates describing the same underlying bug and handle them once.
6. If the finding is a false positive, mark it handled and move on without reporting it in the final summary.
7. If the finding is valid, fix it immediately in the working tree.
8. Re-read the resulting code and run the narrowest relevant verification before moving on.

Continue the loop:

**poll -> triage new issues -> fix valid ones -> verify -> poll again**

until `is_final` is true.

### 6. Close the loop after the final snapshot

Once the review is final:

1. Make sure there are no unhandled valid findings left from the final status payload.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes to the reviewed code, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at **one** follow-up pass unless the user asks for more.
4. Let the attached `codereview` process exit naturally. If it is still alive after the final snapshot and you no longer need it, stop it cleanly.

### 7. Present only the issues you addressed

When you report back:

- List only the issues you actually addressed.
- Summarize the concrete fix for each addressed issue.
- Include the verification you ran.
- Omit false positives, ignored findings, and internal triage counts.

Do **not** commit or push.
