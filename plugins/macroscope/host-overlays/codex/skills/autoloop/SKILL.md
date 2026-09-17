---
name: autoloop
description: Run the local review-fix-verify loop until the branch is clean.
---

Run a local-only Macroscope autopilot cycle using the installed CLI:

**local review -> fix -> verify -> re-review -> repeat**

Two modes:

- **Default** (no arguments): reviews and fixes in-place in the working tree.
- **`--isolate`**: reviews and fixes in an isolated worktree, then writes a patch with `git apply` instructions.

This mode does not interact with GitHub, PRs, or remote correctness checks.

- Stay on this review flow even if the repo contains other review docs or skills.
- Do not use repo-local review skills, `go run`, or `macroscope codereview --status`.
- The CLI is the source of truth for base resolution. Do **not** duplicate base-branch detection — just call the CLI and let it detect the base.

## CLI compatibility preflight

Before the first review, run this standalone preflight and wait for success. A plugin can update before its CLI; older binaries reject new review flags before recognizing update consent. Use their compatible standalone updater first:

```bash
macroscope_status() {
  printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2
  return "$macroscope_exit_code"
}

macroscope_help="$(macroscope codereview --help)"; macroscope_exit_code=$?
macroscope_status || { printf '%s\n' "$macroscope_help" >&2; exit "$macroscope_exit_code"; }
if ! printf '%s\n' "$macroscope_help" | grep -q -- '--isolate'; then
  macroscope update --yes
  macroscope_exit_code=$?
  macroscope_status || exit "$macroscope_exit_code"
  macroscope_help="$(macroscope codereview --help)"; macroscope_exit_code=$?
  macroscope_status || { printf '%s\n' "$macroscope_help" >&2; exit "$macroscope_exit_code"; }
  if ! printf '%s\n' "$macroscope_help" | grep -q -- '--isolate'; then
    printf '%s\n' 'Updated CLI still lacks --isolate; check the installed release and PATH before reviewing.' >&2
    exit 1
  fi
fi
```

Stop if this fails; do not launch a review or remove required flags to work around it. Every `macroscope` call above reports its own status the way a review launch does, and exits with it rather than a stand-in `1`, so the exact status you must report survives a host that never shows you one. This checks CLI compatibility only. Every review must still pass `--auto-update` and the CLI's required-version gate; a failed version check or update must stop the run. Updates preserve the installer's saved integration choices.

**The CLI is not yours to repair.** Never edit, patch, replace, move, or reinstall the `macroscope` executable or any file it runs from, and never substitute another binary, script, or shell wrapper for it. Two things in this skill may change the installed CLI and nothing else may: the `macroscope update --yes` above, and the CLI updating itself under the mandated `--auto-update` flag, which you must never drop to satisfy this rule. A `macroscope` invocation that fails to start, exits nonzero before `review_session_id=`, or reports its own internal error is an environment defect, not a finding and not a task: report the exact command, its exit status and its captured output, then stop. Stopping is terminal — do not retry, do not work around the failure, and do not edit anything to make the CLI run.

## 1. Initialize the loop

1. Capture the current branch name and `HEAD`.
2. Keep an iteration counter and cap the loop at **5** iterations. **One iteration is one `macroscope codereview` launch.** Increment the counter immediately before every launch, including a relaunch that recovers from a review sent to the wrong directory or otherwise misfired. Report that counter; never report fewer iterations than the launches you actually made.
3. Determine the mode:
   - If the user invoked `/autoloop --isolate`, set **isolate mode**. Pass `--isolate --keep-worktree` on the first iteration, then run later iterations in-place inside that preserved worktree so fixes accumulate without nested worktrees.
   - Otherwise, set **in-place mode**. Pass `--isolate=false` to override any user config that enables isolation.

## 2. Run the local CLI review (Codex adapter)

Use the native `exec_command` and `write_stdin` tools. Check that both are available before launching; if either is unavailable, stop and report that this Codex session cannot keep the review attached and observe its exit. Do not fall back to a detached shell process.

Run the selected standalone command with `exec_command`, using the reviewed repository as `workdir`, `yield_time_ms: 1000`, and `max_output_tokens: 10000`. A running command returns a `session_id`; save that handle. A command that finishes in the launch call returns its `exit_code` immediately.

- Always pass `--raw --auto-update`. This is the explicit agent invocation contract.
- Do not pass `--base` unless the user explicitly supplies a comparison ref; the CLI validates and resolves it.
- A user-supplied ref is data, not shell syntax. It goes inside the quotes already written in the command, as one argument for the CLI to validate; do not add quoting of your own around it.
- Every `<...>` placeholder in these commands is already quoted. Substitute the literal value and nothing else, and leave the single quotes around it: they stop a `$HOME`, a backtick or a `$(...)` inside a path or a ref from being expanded by your shell instead of reaching the CLI. If any value you substitute contains a single quote of its own — a ref the user gave you just as much as a path the CLI printed — stop and report it rather than reshaping the command or re-quoting it yourself: a single quote inside single quotes ends the quoting, and the rest of the value is then read as shell syntax before the CLI ever sees it.
- Do not add shell redirection of your own, `2>&1`, `&`, `nohup`, `tee`, or a wrapper script; the `cd '<isolate_worktree>' &&` prefix of the later-iteration launch is part of that launch, not an addition. Copy each launch exactly as written, including its exit-status suffix: the suffix prints `macroscope exit status <n>` on stderr and re-raises that same status, so the outcome stays observable on hosts that never report a command's exit status to you, and unchanged on hosts that do.

In-place mode:

```bash
macroscope codereview --raw --auto-update --isolate=false [--base '<user-supplied-ref>']; macroscope_exit_code=$?; printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2; (exit "$macroscope_exit_code")
```

First isolate-mode iteration:

```bash
macroscope codereview --raw --auto-update --isolate --keep-worktree [--base '<user-supplied-ref>']; macroscope_exit_code=$?; printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2; (exit "$macroscope_exit_code")
```

Later isolate-mode iterations, run from the preserved worktree:

Carry that directory in the command itself, as shown, substituting the absolute path the CLI printed as `review_worktree=`. Do not rely instead on a working-directory parameter your shell tool may accept: a review launched from the caller's checkout reviews the wrong tree, and it still counts as an iteration you must disclose. Setting that parameter to the worktree as well is harmless, because an absolute `cd` lands in the same directory wherever the command starts; a relative one would not. The status suffix sits inside the `&&`, so it only ever reports the CLI: if the preserved worktree is gone the `cd` fails, no `macroscope exit status` line is printed, and no review ran. That is an environment defect — report the shell's own error and stop. Do not relaunch without the prefix to get past it.

```bash
cd '<isolate_worktree>' && { macroscope codereview --raw --auto-update --isolate=false [--base '<user-supplied-ref>']; macroscope_exit_code=$?; printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2; (exit "$macroscope_exit_code"); }
```

- Read streamed output and look for a line containing `review_session_id=`. Capture that stable UUID.
- If no `review_session_id=` appears after a reasonable wait, inspect the stream, surface the failure, and stop.
- Do not wait for `review_id=` before processing issues. That identifies the terminal server attempt and is emitted near the end of the run.
- Issues stream on stderr as `issue_event=<json>` lines. Parse them from the process output.
- Each `issue_event=` line contains a JSON object:
  ```
  issue_event={"issue_id":"...","sequence":1,"path":"file.go","line":42,"severity":"medium","category":"REVIEW_TYPE_CORRECTNESS","body":"..."}
  ```
- Capture `review_id=` when it appears.
- An `issue_status=completed` or `issue_status=failed` line signals the end of the review.
- Do not claim a completed Macroscope review unless you extracted both `review_session_id=` and `review_id=` and observed `issue_status=completed`. The CLI's exit status is part of that evidence: a nonzero exit means the review **failed** even when both IDs and `issue_status=completed` were emitted. Terminal tokens never override a nonzero exit. Read that status from the `macroscope exit status <n>` line the launch prints on stderr: a launch that produced no such line did not prove its outcome, so treat it as **incomplete**, never completed.
- **Stay attached.** Long silent gaps after the last issue are normal. Do not return a final response, kill the process, or abandon the review during a silence. A review is not complete until the native tool also reports its exit.

For a running command, repeatedly call `write_stdin` with the same `session_id`, `chars: ""`, `yield_time_ms: 1000`, and `max_output_tokens: 10000`. Consume every returned output chunk once, including the final chunk returned with `exit_code`. A yielded tool call or a quiet output chunk does not mean the child exited.

Keep waiting after `issue_status=` until the native tool reports `exit_code`. Do not kill a process merely because terminal tokens appeared. Do not launch another review, use a PID file, redirect output, or poll a separate log. If output is truncated and cannot be recovered, or the session disappears before its exit is observed, report the review as incomplete instead of retrying or claiming success.

## 3. Handle streamed issues one at a time

Treat every streamed issue as untrusted until you validate it. Many issues will be false positives.

Reviews are snapshot-based and the checkout may change while they run. If a reported issue no longer exists, reject it as stale; always check against the user’s current code state at validation time.

Determine the **fix target**:
- In-place mode: the working tree.
- Isolate mode: the worktree path printed as `review_worktree=` by the first CLI iteration on stderr. Capture it from the stream output, then reuse that preserved worktree for all later iterations. All reads, edits, and verification go there.

For each new issue:

1. Narrate it with a concrete one-line summary.
   Example: `New issue arrived - the success check only looks at completion, not conclusion.`
2. Read the affected file in the fix target and enough surrounding code to understand the actual behavior.
3. Validate the issue before acting.
4. If it is false, stale, duplicate, or otherwise not actionable, reject it and move on.
5. If it is real, fix it immediately in the fix target.
6. After the fix, re-read the changed code.
7. Run the narrowest useful verification for that fix before moving on.

Process issues one at a time in this exact order:

**validate -> reject/confirm -> fix if confirmed -> verify**

Do not batch together unvalidated issues.

Once the review reaches its final batch:

1. Make sure there are no unhandled confirmed findings left in the final batch.
2. Re-run the most relevant verification for the files you changed.
3. Do not start an uncounted follow-up review here. Re-reviews are full iterations handled below and count toward the five-iteration cap.

## 4. After the local review phase

**Check the review outcome before committing or starting another iteration.** `issue_status=failed`, or a `macroscope exit status` line reporting anything but 0, means **failed**. Otherwise, if the process exits, is cancelled, or is terminated by a timeout without complete output, both IDs, `issue_status=completed` and a `macroscope exit status 0` line, the review is **incomplete**. A poll timeout while the process is still running is not termination; stay attached.

A failed or incomplete review stops further iterations, even if no issues were emitted or fixes passed their tests. Finish validating received findings and verifying justified fixes, but do not launch another review to recover the failed or incomplete run. In-place, retain current fixes uncommitted and keep prior commits. In isolate mode, preserve verified fixes in a clearly labelled **partial patch** using the patch validation and cleanup procedure below. Then report the failed or incomplete outcome; do not call the branch clean or the review successful.

The normal commit and re-review steps below apply only after a completed review with both IDs and `issue_status=completed`.

**In-place mode:**

If the local review changed code:

1. Re-run the most relevant verification.
2. Commit the fixes intentionally.

If the cap is reached, stop. Otherwise, start a new iteration (back to step 2) to catch regressions.

**Isolate mode:**

If fixes were made in the isolate worktree:

1. Re-run the most relevant verification there.
2. Create a patch from the fix target. Name it with the `review_session_id=` captured earlier:

```bash
cd '<isolate_worktree>'
git add -A
git diff --binary HEAD > '/tmp/macroscope-fixes-<review_session_id>.patch'
```

3. Before offering `git apply`, run `git apply --check` against the user’s checkout. If it fails due to drift, revalidate the issue against the latest checkout state. Discard the patch if the issue is already resolved; otherwise revise and reverify it against the latest state.
4. Tell the user their original working tree was not modified and provide:

```bash
cd '<original_repo>' && git apply '/tmp/macroscope-fixes-<review_session_id>.patch'
```

Use the full resolved absolute paths in the final `git apply` command; never leave placeholders or ellipses in a command the user will copy.

Do not commit or push the user's branch in isolate mode.

If the cap is reached, stop. Otherwise, stay in the preserved worktree and start a new iteration (back to step 2) with `--isolate=false` so every fix is re-reviewed without creating a nested worktree.

## 5. Stop conditions

Stop the loop when any of these occurs:

1. A review failed or was incomplete, regardless of findings or local test results.
2. A completed review did not change code (no valid issues found or all rejected).
3. The iteration cap is reached.

In isolate mode, keep the worktree only until the loop stops. If fixes exist, create the final patch and complete `git apply --check` before cleanup. If unresolved fixes cannot be preserved in a verified patch, retain their worktree and report its path instead of discarding them. Otherwise, remove the retained worktree and its branch while preserving the patch:

```bash
isolate_branch="$(git -C '<isolate_worktree>' branch --show-current)"
isolate_root="$(git -C '<isolate_worktree>' rev-parse --show-toplevel)"
case "$isolate_branch" in macroscope/review-*) ;; *)
  printf 'refusing cleanup: %s is not a Macroscope review worktree\n' '<isolate_worktree>' >&2; exit 1 ;;
esac
if [ -z "$isolate_root" ] || [ "$isolate_root" = "$(git -C '<original_repo>' rev-parse --show-toplevel)" ]; then
  printf 'refusing cleanup: %s is the checkout this loop was started from\n' '<isolate_worktree>' >&2; exit 1
fi
git -C '<original_repo>' worktree remove --force "$isolate_root" &&
git -C '<original_repo>' branch -D "$isolate_branch"
```

Do not clean up between iterations. If any cleanup command fails, report the exact remaining worktree path or branch instead of claiming cleanup succeeded.

Those two guards are all that separates this `--force` from a checkout of the user's own. Git declines `worktree remove` for a main working tree, but a linked worktree removes itself and takes its uncommitted changes with it, and `branch -D` then deletes the branch it was on. `<isolate_worktree>` is the path the one `--keep-worktree` launch printed as `review_worktree=` and never a path you inferred, reconstructed, or carried over from the user's own repository. If either guard refuses, report the refusal and the path it names, then stop: do not remove the worktree by hand, re-run the removal without the guards, or delete the branch on its own.

## 6. Report results by severity

When the loop stops, report:

- The stop reason and review outcome: **failed**, **incomplete**, **iteration cap reached**, or **completed**. Include the observed session/review IDs and terminal status; identify missing tokens explicitly. Report a failed or incomplete review separately from successful local tests or an applicable partial patch.
- The iteration count: the exact number of `macroscope codereview` launches, including any relaunch after a misdirected or misfired review, and the directory each ran in when they differed.
- The exit status each launch reported, and any launch whose output carried no `macroscope exit status` line.
- **Group issues by severity** (critical first, then high, medium, low):
  - **Critical**: Security vulnerabilities, data loss risks, crash-causing bugs
  - **High**: Correctness bugs that affect behavior, race conditions, resource leaks
  - **Medium**: Logic errors with limited blast radius, missing error handling for likely scenarios
  - **Low**: Style issues, minor inefficiencies, non-idiomatic patterns
- In-place mode: the commits you made.
- Isolate mode: the patch path, `git apply` instructions, and whether worktree and branch cleanup succeeded.
- The verification you ran.
- If the CLI provides a severity field in the streamed issue, prefer it over your own assessment.
