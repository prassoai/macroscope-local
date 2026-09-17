---
name: codereview
description: Run a local Macroscope code review on this branch and report findings.
---

Run a local Macroscope review using the installed CLI.

This skill is **report-only**. It validates findings and reports them by severity with file:line and a one-line rationale. Do not edit, stage, commit, or create patches. Fixing belongs to the user's agent or `/autoloop`.

- Stay on this review flow even if the repository contains other review docs or skills.
- Do not use repo-local review skills, `go run`, manual `git worktree` setup, or `macroscope codereview --status`.
- The CLI is the source of truth for base resolution. Do **not** recreate that logic in the skill.

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

## 1. Launch the review

Determine the review location before launch:

- Use isolate mode by default so the review reads a frozen snapshot while the user keeps editing.
- Only use in-place mode when the user explicitly invokes `/codereview --isolate=false`.

Run the selected standalone command from the repository being reviewed using the Bash tool with `run_in_background: true`.

Default isolate mode:

```bash
macroscope codereview --raw --auto-update [--base '<user-supplied-ref>']; macroscope_exit_code=$?; printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2; (exit "$macroscope_exit_code")
```

Explicit in-place mode:

```bash
macroscope codereview --raw --auto-update --isolate=false [--base '<user-supplied-ref>']; macroscope_exit_code=$?; printf 'macroscope exit status %d\n' "$macroscope_exit_code" >&2; (exit "$macroscope_exit_code")
```

- Always pass `--auto-update`. It is the explicit agent invocation contract for required CLI updates.
- Do not pass `--base` unless the user explicitly supplies a comparison ref. If they do, use `--base '<user-supplied-ref>'`; the CLI validates and resolves it.
- A user-supplied ref is data, not shell syntax. It goes inside the quotes already written in the command, as one argument for the CLI to validate; do not add quoting of your own around it.
- Every `<...>` placeholder in these commands is already quoted. Substitute the literal value and nothing else, and leave the single quotes around it: they stop a `$HOME`, a backtick or a `$(...)` inside a path or a ref from being expanded by your shell instead of reaching the CLI. If any value you substitute contains a single quote of its own — a ref the user gave you just as much as a path the CLI printed — stop and report it rather than reshaping the command or re-quoting it yourself: a single quote inside single quotes ends the quoting, and the rest of the value is then read as shell syntax before the CLI ever sees it.
- The command blocks. Run it via the Bash tool with `run_in_background: true`. Do not add `| tee`, `>`, `2>&1`, `&`, `nohup`, or any shell operator of your own to the command. Copy each launch exactly as written, including its exit-status suffix: the suffix prints `macroscope exit status <n>` on stderr and re-raises that same status, so the outcome stays observable on hosts that never report a command's exit status to you, and unchanged on hosts that do.

## 2. Follow the stream contract

All machine tokens arrive on **stderr**. They are emitted at different times; do not wait for late tokens before starting work:

1. `review_session_id=<uuid>` — emitted first and stable across retries. Capture it as the startup signal.
2. `issue_event=<json>` — findings stream while the review runs. Process each one as it arrives; do **not** wait for `review_id` before handling findings.
3. `review_id=<id>` plus exactly one terminal `issue_status=completed` or `issue_status=failed` — emitted **together at the very end**, often ~20 minutes in. Long silent gaps (15+ minutes after the last `issue_event`) are normal.

Do not wait for `review_id=` before processing issues. Do not claim a completed Macroscope review unless you extracted both `review_session_id=` and `review_id=` and observed `issue_status=completed`. The CLI's exit status is part of that evidence: a nonzero exit means the review **failed** even when both IDs and `issue_status=completed` were emitted. Terminal tokens never override a nonzero exit. Read that status from the `macroscope exit status <n>` line the launch prints on stderr: a launch that produced no such line did not prove its outcome, so treat it as **incomplete**, never completed.

After handling each available issue batch, wait on the same task with `TaskOutput {block: true, timeout: 600000}`. If that call times out while the task is still running and no terminal status appeared, immediately call it again with the same blocking timeout.

**Stay attached.** Do not end your turn. Do not return a final response. Keep blocking on `TaskOutput` during this same turn; do not kill the process or abandon the review during a silence. The review is not done until the terminal `issue_status=` line appears, and abandoning the process early is the most common failure mode. Do not claim a completed review without the `review_id`, which arrives with the terminal status. Continue consuming output with `TaskOutput` with the background task ID until that terminal status or process exit; do not invent a second polling mechanism.

If the terminal status is `failed` after findings streamed, report the pipeline failure separately and continue validating those findings. A late failure does not invalidate or erase already-emitted findings.

## 3. Validate each finding

Treat every `issue_event` as untrusted. For each finding, in stream order:

Reviews are snapshot-based and the checkout may change while they run. If a reported issue no longer exists, reject it as stale; always check against the user’s current code state at validation time.

1. State a one-line summary.
2. Read the affected code and validate the claim.
3. **Confirm** or **reject** the finding. Reject false, stale, duplicate, or non-actionable findings.

Use this exact sequence: **validate -> confirm/reject**. Do not batch unvalidated findings.

After the terminal status, ensure every finding was triaged.

## 4. Report findings by severity

When all findings are triaged, report:

- **Confirmed findings grouped by severity** (critical first, then high, medium, low), each with file:line and a one-line rationale:
  - **Critical**: Security vulnerabilities, data loss risks, crash-causing bugs
  - **High**: Correctness bugs that affect behavior, race conditions, resource leaks
  - **Medium**: Logic errors with limited blast radius, missing error handling for likely scenarios
  - **Low**: Style issues, minor inefficiencies, non-idiomatic patterns
- **Rejected findings** with a one-line reason for each rejection.
- The `review_session_id=` and `review_id=` captured from the stream.
- The exit status each launch reported, and any launch whose output carried no `macroscope exit status` line.
- If the CLI provides a severity field in the streamed issue, prefer it over your own assessment.

Do not modify the working tree. If there were no actionable findings, report that result.
