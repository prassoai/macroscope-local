---
name: macroscope
description: Main Macroscope entrypoint. `/macroscope` runs the local CLI review path by default. `/macroscope loop` runs the full autopilot cycle.
argument-hint: [loop]
---

Use this as the canonical Macroscope entrypoint.

If the user mentions `macroscope` at all, start here unless they are explicitly asking for one of the narrower follow-up workers by name.

Default behavior:

- With no arguments, run the local CLI review workflow immediately.
- Do **not** skip straight to PR comment triage just because there is an open PR or a successful check.

## Steps

### 1. Parse the invocation mode

- If the first argument is exactly `loop`, run the autopilot flow from Step 3.
- Otherwise, run the default local-review flow from Step 2.

### 2. Default to the local CLI review workflow

With no arguments:

1. Open `../skills/macroscope-local-review/SKILL.md`.
2. Follow that workflow exactly.
3. Report only the issues you addressed.
4. Do **not** commit or push in this default mode.

### 3. `loop` mode: full autopilot

In `loop` mode, run the full:

**review -> fix -> push -> wait for Macroscope correctness check -> triage PR comments -> fix -> push -> repeat**

cycle until there is nothing left to address.

Use the same autopilot flow as the `macroscope` skill:

1. Run `../skills/macroscope-local-review/SKILL.md` first on each iteration.
2. If it changes code, verify, commit, and push.
3. Wait for a successful `Macroscope - Correctness Check` or `Review for correctness` on the exact current `HEAD`, clamping every polling sleep to `60` seconds max and never compounding sleeps.
4. Once the current `HEAD` has a successful check, run `../skills/macroscope-triage-pr-comments/SKILL.md`.
5. Use that triage for investigation/classification, but do not pause for its final user-confirmation prompt in loop mode.
6. If there are believed-valid comments, immediately run `../skills/macroscope-respond-to-pr-comments/SKILL.md`.
6. If that phase changes code, verify, commit, push, and continue the loop.
7. Stop when the current iteration makes no code changes and there are no believed-valid unresolved Macroscope comments left for the successful current `HEAD`.

Cap the autopilot loop at **5** iterations so it cannot spin forever.

### 4. Respect explicit user intent when it is narrower than the top-level Macroscope entrypoint

- If the user explicitly asks to act on a previously triaged PR comment list, skip this entrypoint and use `/macroscope-respond-to-pr-comments`.
- If the user explicitly asks for a general review of the PR diff itself rather than local CLI review, use `/macroscope-review-pr`.
