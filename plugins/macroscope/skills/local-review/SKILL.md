---
name: local-review
description: Run a local Macroscope review with the installed CLI, triage streaming findings, fix the valid ones, and report only the issues you addressed.
---

Run a code review using the installed `macroscope` CLI, then triage streaming issues as they arrive. This is the no-open-PR path for `/macroscope:review`.

This workflow is **closed-loop**:

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

### 1. Start the blocking review in the background

The `codereview` command is **blocking**. It maintains an agent loop for tool calls and a watch stream for progress until the review completes. Run it in the background so you can poll from the foreground:

```bash
macroscope codereview --base <base_branch> >/tmp/review-stdout.log 2>/tmp/review-stderr.log &
```

Keep this background process alive while you poll. It is servicing the remote review agent's tool calls.

### 2. Extract the review ID

Wait for the build/upload/start phase to complete, then extract the `review_id` from stderr:

```bash
grep -m1 'review_id=' /tmp/review-stderr.log
```

Save this JWT. You need it for polling partial results.

If no `review_id` appears after a reasonable wait, inspect `/tmp/review-stderr.log`, surface the failure, and stop.

### 3. Poll for partial results

While the background process runs, poll for incremental results:

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

Maintain a seen-set of issue fingerprints so you only process newly surfaced findings on each poll. Use a stable fingerprint such as:

`path:start_line:end_line:category:message`

### 4. Triage and fix issues as they arrive

Don't wait for the review to finish. As soon as issues appear in a poll response, start triaging and fixing new findings.

<triage_rules>
For each issue, read the affected file and evaluate whether the finding is legitimate. Classify each as:

- **Valid**: The issue is real and should be fixed.
- **False positive**: The reviewer misunderstood the code or the issue was already addressed elsewhere.
</triage_rules>

For each **new** finding:

1. Read the relevant file and surrounding code, not just the cited lines.
2. Check the existing codebase patterns and trace the code paths the claim depends on.
3. Group duplicates describing the same underlying bug and handle them once.
4. If the finding is a false positive, mark it handled and move on without reporting it to the user.
5. If the finding is valid, fix it immediately in the working tree.
6. Re-read the resulting code and run the narrowest relevant verification before moving on.

Continue the loop:

**poll → triage new issues → fix valid ones → verify → poll again**

until `is_final` is true.

### 5. Close the loop after the final snapshot

Once the review is final:

1. Make sure there are no unhandled valid findings left from the final status payload.
2. Re-run the most relevant verification for the files you changed.
3. If you made substantial fixes to the reviewed code, prefer one follow-up local review pass to catch regressions or newly exposed issues. Cap yourself at **one** follow-up pass unless the user asks for more.
4. Let the background `codereview` process exit naturally. If it is still alive after the final snapshot and you no longer need it, stop it cleanly.

### 6. Present only the issues you addressed

When you report back:

- List only the issues you actually addressed.
- Summarize the concrete fix for each addressed issue.
- Include the verification you ran.
- Omit false positives, ignored findings, and internal triage counts.

Do **not** commit or push.
