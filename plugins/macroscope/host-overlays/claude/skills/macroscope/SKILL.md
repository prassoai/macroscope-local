---
name: macroscope
description: Main Macroscope entrypoint. `/macroscope` runs the local CLI review path by default. `/macroscope loop` runs the full review-fix-push-re-review cycle until the branch is clean.
argument-hint: [loop]
disable-model-invocation: true
context: fork
agent: macroscope-review-worker
---

Run Macroscope for the current branch.

If `$ARGUMENTS` is exactly `loop`, run the full review-fix-push-re-review cycle.
Otherwise, run the default local CLI review flow.
