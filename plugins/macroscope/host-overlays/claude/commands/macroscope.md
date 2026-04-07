---
name: macroscope
description: Run a local Macroscope review. Use `/macroscope loop` for the full review-fix-push-re-review cycle.
argument-hint: [loop]
disable-model-invocation: true
allowed-tools: Task
---

Use the Task tool immediately to launch the `macroscope:macroscope-review-worker` agent.

Give it this prompt:

```text
Run Macroscope for the current branch.

If "$ARGUMENTS" is exactly "loop", run the full review-fix-push-re-review cycle.
Otherwise, run the default local CLI review flow.

Use the installed `macroscope` CLI.
Follow this flow exactly:
start review -> extract review_id -> next-comment -> narrate -> validate -> reject/confirm -> fix -> verify
```

Do not do anything else in the current agent before you launch that worker.
