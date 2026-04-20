#!/usr/bin/env python3
"""PreToolUse hook for Claude Code. Auto-approves Bash tool calls whose
command starts with `macroscope` or `mktemp` (optionally followed by args,
pipes, redirects, or command substitution). Claude Code's permission
allow-list patterns stop matching as soon as a shell operator appears in
the command, so the /macroscope:review and /macroscope:loop skills would
otherwise stall on every piped / redirected / substituted invocation even
after the installer writes `Bash(macroscope *)`.

Reads the tool call as JSON on stdin, emits a JSON decision on stdout.
Empty output falls through to Claude Code's default permission flow, so
unrelated Bash calls are unaffected.

Installed by install.sh into ~/.claude/hooks/ and registered in
~/.claude/settings.json under hooks.PreToolUse[].
"""
import json
import re
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    command = str(payload.get("tool_input", {}).get("command", "")).strip()
    if not command:
        return 0

    # Allow any Bash invocation where the effective command word is
    # `macroscope` or `mktemp`. This covers:
    #   macroscope codereview --base staging
    #   macroscope codereview ... > log 2>&1
    #   review_log=$(mktemp /tmp/foo.XXX)
    #   mktemp "${TMPDIR:-/tmp}/foo.XXX"
    # while still falling through for unrelated commands like `git` or `ls`.
    # Word-boundary matching avoids false positives in string literals such
    # as `echo 'macroscope should not match this'` — those are rare in the
    # skill workflow and fall through to the installer's static allow rules.
    for name in ("macroscope", "mktemp"):
        # Match `name` at start, after whitespace, after `$(`, or after `|` —
        # i.e. as a command word in normal shell usage — not inside a quoted
        # string literal.
        pattern = r"(?:^|[\s;|&=(]|[$]\()" + re.escape(name) + r"(?:\s|$|;|\||&|>|<)"
        if re.search(pattern, command):
            # Claude Code's PreToolUse hook expects the permission decision
            # nested under hookSpecificOutput. A flat {"permissionDecision":
            # "allow"} is silently ignored and the static allow-list takes
            # over, so piped/redirected/substituted forms would still prompt.
            # See ~/.claude/plugins/marketplaces/claude-plugins-official/
            # plugins/plugin-dev/skills/hook-development/SKILL.md for schema.
            print(json.dumps({
                "hookSpecificOutput": {
                    "permissionDecision": "allow",
                    "permissionDecisionReason": f"macroscope-installer: auto-approve {name}",
                },
            }))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
