---
name: macroscope
description: Main Macroscope entrypoint. `/macroscope` runs the local CLI review path by default. `/macroscope loop` runs the full review-fix-push-re-review autopilot cycle until there is nothing left to address.
argument-hint: [loop]
---

Use this as the canonical Macroscope entrypoint.

If the user mentions `macroscope` at all, start here unless they are explicitly asking for one of the narrower follow-up workers by name.

Invocation:

- Claude Code: `/macroscope`
- Claude Code autopilot: `/macroscope loop`
- Codex and Cursor: `/macroscope:macroscope`
- Codex and Cursor autopilot: `/macroscope:macroscope loop`
- OpenCode: `/macroscope`
- OpenCode autopilot: `/macroscope loop`

Default behavior:

- With no arguments, run the local CLI review workflow immediately.
- Do **not** skip straight to PR comment triage just because there is an open PR or a successful check.
- The explicit PR workers are `macroscope-triage-pr-comments`, `macroscope-respond-to-pr-comments`, and `macroscope-review-pr`.

Loop behavior:

- If the first argument is `loop`, run the autopilot cycle in this skill instead of the default local-review path.

## Steps

### 1. Parse the invocation mode

Treat the first argument as the mode selector:

- If it is exactly `loop`, run the autopilot flow from Step 3.
- Otherwise, run the default local-review flow from Step 2.

### 2. Default to the local CLI review workflow

With no arguments, this command should behave like the local-review worker:

1. Open `../macroscope-local-review/SKILL.md`.
2. Follow that workflow exactly.
3. Report only the issues you addressed.
4. Do **not** commit or push in this default mode.

### 3. `loop` mode: full autopilot

Use this mode for the full iterative cycle:

**review -> fix -> push -> wait for Macroscope correctness check -> triage PR comments -> fix -> push -> repeat**

This mode is allowed to commit and push. Stay in the loop until there is nothing left to address or you hit a hard stop.

#### 3a. Establish the loop state

At the start:

1. Capture the current branch name and `HEAD`.
2. Determine whether the branch has an open PR:

```bash
gh pr view --json number,title,url,headRefOid,statusCheckRollup 2>/dev/null
```

3. Keep an iteration counter and cap the loop at **5** iterations so you do not spin forever.

#### 3b. Run the local-review worker first

Each iteration starts with the local CLI review path:

1. Open `../macroscope-local-review/SKILL.md`.
2. Follow it exactly.
3. Record whether it actually changed code.

If the local-review worker made changes:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.
3. Push the branch.
4. Refresh the current `HEAD`.

#### 3c. Wait for Macroscope correctness review on the current HEAD

After every push in loop mode, wait for the current pushed `HEAD` to receive a successful Macroscope correctness check before using the PR-comment workers.

Poll:

```bash
gh pr view --json number,title,url,headRefOid,statusCheckRollup 2>/dev/null
```

Treat the check as ready only when all of these are true for the current local `HEAD`:

1. `gh pr view` succeeds.
2. `headRefOid` exactly matches the current local `HEAD`.
3. `statusCheckRollup` contains a GitHub check run named `Macroscope - Correctness Check`.
   For compatibility, also accept `Review for correctness`.
4. That check has `status == "COMPLETED"`, `conclusion == "SUCCESS"`, and a non-null `completedAt`.

Use a simple polling cadence:

- If the host or workflow gives you a suggested sleep, clamp it to `60` seconds max.
- Never compound the sleep across cycles.
- Default to `30` seconds when no better signal is available.

If the check finishes with a non-success conclusion, stop the loop and tell the user the remote review failed instead of guessing.

#### 3d. Triage and respond to PR comments for the current successful HEAD

Once the current `HEAD` has a successful Macroscope correctness check:

1. Open `../macroscope-triage-pr-comments/SKILL.md`.
2. Follow its investigation and classification steps, but in `/macroscope loop` do **not** pause for its final user-confirmation prompt.
3. Treat the believed-valid findings from that triage as the working set for this loop iteration.
4. If the triage finds believed-valid comments, immediately open `../macroscope-respond-to-pr-comments/SKILL.md` and act on them in the same loop mode.
5. Record whether the PR-comment response phase changed code.

If the PR-comment response phase made changes:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.
3. Push the branch.
4. Continue to the next iteration so the new `HEAD` gets reviewed.

#### 3e. Stop conditions

Stop the loop when all of the following are true in the same iteration:

1. The local-review phase did not change code.
2. The PR-comment response phase did not change code.
3. The current local `HEAD` already has a successful Macroscope correctness check.
4. There are no believed-valid unresolved Macroscope comments left to address for that `HEAD`.

When you stop, summarize the issues you addressed, the commits you pushed, and the verification you ran.

### 4. Respect explicit user intent when it is narrower than the top-level Macroscope entrypoint

- If the user explicitly asks to act on a previously triaged PR comment list, skip this entrypoint and use `../macroscope-respond-to-pr-comments/SKILL.md`.
- If the user explicitly asks for a general review of the PR diff itself rather than local CLI review, use `../macroscope-review-pr/SKILL.md`.
