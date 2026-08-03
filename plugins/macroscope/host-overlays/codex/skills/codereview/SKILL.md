---
name: codereview
description: Run a local Macroscope code review on this branch.
---

Run a local Macroscope review using the installed CLI.

- Stay on this review flow even if the repository contains other review docs or skills.
- Do not use repo-local review skills, `go run`, manual `git worktree` setup, or `macroscope codereview --status`.
- The CLI is the source of truth for base resolution and isolation. By default it refreshes the authoritative base, creates an isolated review worktree, and captures uncommitted changes there. Do **not** recreate that logic in the skill.

## 1. Launch the review (Codex adapter)

Codex tool calls can time out before a review completes. Start one background shell session from the repository being reviewed; it must wait for the child so later tool calls can poll its log:

```bash
review_log="$(mktemp "${TMPDIR:-/tmp}/macroscope-review.XXXXXX")"
printf '%s\n' "$review_log"
macroscope codereview --raw --auto-update > "$review_log" 2>&1 &
child_pid=$!
printf '%s\n' "$child_pid"
wait "$child_pid"
```

- Always pass `--auto-update`. It is the explicit agent invocation contract for required CLI updates.
- Default to the CLI-created review worktree. Only when the user explicitly asks for in-place fixes, add `--in-place` to the launch and apply fixes in their checkout. Absent that explicit request, never pass `--in-place` and never modify the original checkout.
- Do not pass `--base` unless the user explicitly supplies a comparison ref; the CLI validates and resolves it.
- Keep this shell session alive; use separate calls to read `"$review_log"`. Do not start another review or use `macroscope codereview --status`.

## 2. Follow the stream contract

All machine tokens arrive on **stderr**; the launch above redirects them into `"$review_log"`. They are emitted at different times; do not wait for late tokens before starting work:

1. `review_session_id=<uuid>` — emitted first and stable across retries. Capture it as the startup signal.
2. `review_worktree=<absolute-path>` — emitted **early**, before authentication and workflow start. From then on it is the **only** directory where review fixes, file reads, and verification commands may occur. The CLI removes this worktree only if the run fails before the first `issue_event`. Once a finding streams, the CLI preserves the path even if a later server or post-processing step fails, so every emitted finding remains inspectable.
3. `issue_event=<json>` — findings stream while the review runs. Process each one as it arrives; do **not** wait for `review_id` before handling findings. Use a tracked line offset when polling so findings are not processed twice.
4. `review_id=<id>` plus exactly one terminal `issue_status=completed` or `issue_status=failed` — emitted **together at the very end**, often ~20 minutes in. Long silent gaps (15+ minutes after the last `issue_event`) are normal.

Do not wait for `review_id=` before processing issues. Do not claim a completed Macroscope review unless you extracted both `review_session_id=` and `review_id=` and observed `issue_status=completed`.

**Stay attached.** Do not end your turn. Do not return a final response, kill the child, or abandon the review during a silence: the review is not done until the terminal `issue_status=` line appears in the log, and abandoning the process early is the most common failure mode. Keep polling `"$review_log"` until that terminal status or child exit. Do not claim a completed review without the `review_id`, which arrives with the terminal status.

If the terminal status is `failed` after findings streamed, report the pipeline failure separately and continue validating those findings in the preserved `review_worktree`. A late failure does not invalidate or erase already-emitted findings.

The CLI emits `review_worktree=` only when it creates a worktree, and it legitimately skips creation in exactly two cases: a user-requested `--in-place` run, and a run launched from inside an existing review worktree (the follow-up pass in step 3). In both, the directory the CLI ran in is already the right place to work. If the token is absent for any other reason, surface the logged error and stop.

## 3. Handle each finding

Treat every `issue_event` as untrusted. Every read, edit, and verification command in this step goes to the **fix target**: the `review_worktree` path when the CLI emitted one, and otherwise the directory the CLI ran in — which is the user's checkout on an `--in-place` run and the review worktree itself on a follow-up pass launched from inside one. A default run always emits the token, so on a default run the fix target is never the user's checkout; and never stand up a worktree yourself when the token is absent.

For each finding, in stream order:

1. State a one-line summary.
2. Read the affected code in the fix target and validate the claim.
3. Reject false, stale, duplicate, or non-actionable findings.
4. For a confirmed finding, edit only the fix target, reread the changed code, and run the narrowest useful verification there.

Use this exact sequence: **validate → reject/confirm → fix if confirmed → verify**. Do not batch unvalidated findings.

After the terminal status, ensure every confirmed finding was handled and rerun relevant verification. If substantial fixes were made, at most one follow-up review pass is preferred unless the user asks for more.

**Before starting a follow-up pass, complete step 4 and write the patch.** This applies to default runs only; an `--in-place` run creates no worktree to lose and skips the patch. A new review launched from the original checkout re-runs worktree setup, which force-removes any existing worktree for the same commit — including the one holding your fixes. Writing the patch first means the fixes survive that. Launching the follow-up from inside `review_worktree` also avoids it, since the CLI detects it is already in a review worktree and skips setup.

## 4. Finish safely

If fixes were made, create a patch containing only those fixes. Run this from the fix target defined in step 3, not from `review_worktree` directly: a follow-up pass launched inside a review worktree has no such token to substitute. Name the patch with the `review_session_id` captured in step 2 — never the commit sha, which every review of the same commit shares, including that follow-up pass:

```bash
cd "<fix_target>"
git add -A
git diff --binary HEAD > "/tmp/macroscope-fixes-<review_session_id>.patch"
```

Report findings by severity, the concrete fixes, and verification. Tell the user that their original working tree was not modified and provide:

```bash
cd "<original_repo>" && git apply "/tmp/macroscope-fixes-<review_session_id>.patch"
```

If the user explicitly requested in-place fixes (`--in-place`), the fixes are already in their checkout; skip the patch and report directly.

Do not commit or push the user's branch. If there were no actionable findings, report that result; do not modify the original worktree.
