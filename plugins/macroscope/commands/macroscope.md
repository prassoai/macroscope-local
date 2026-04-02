---
name: macroscope
description: Route the current branch through the right Macroscope review workflow
---

Use the `macroscope` skill from this plugin to review the current branch with Macroscope.

Follow the skill exactly:
- First check whether the current local `HEAD` already has a successful `Macroscope - Correctness Check`.
- If it does, use the PR comment path.
- If it does not, use the local CLI path.

Complete the workflow end to end and report only the issues you addressed.
