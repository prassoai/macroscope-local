#!/usr/bin/env python3
"""PreToolUse hook for Claude Code. Auto-approves single Bash commands whose
command starts with `macroscope` or `mktemp` (optionally followed by args or
backgrounding). Claude Code's permission
allow-list patterns stop matching as soon as a shell operator appears in
the command, so the /macroscope:codereview and /macroscope:autoloop skills would
otherwise stall on backgrounded invocations even
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


def safe_simple_command(command, names):
    candidate = command.strip()
    if candidate.endswith("&"):
        candidate = candidate[:-1].rstrip()
    if not candidate or re.search(r"[\n\r;|`()<>]|[$][(]", candidate):
        return None
    if "&" in candidate:
        return None
    match = re.match(r"^([A-Za-z0-9_.-]+)(?:\s|$)", candidate)
    return match.group(1) if match and match.group(1) in names else None


def approved_command(command):
    assignment = re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[$][(](.*)[)]", command.strip())
    if assignment:
        return safe_simple_command(assignment.group(1), ("mktemp",))
    return safe_simple_command(command, ("macroscope", "mktemp"))


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

    # Approve only a complete single command. This covers:
    #   macroscope codereview --base staging
    #   macroscope codereview --raw &
    #   review_log=$(mktemp /tmp/foo.XXX)
    #   mktemp "${TMPDIR:-/tmp}/foo.XXX"
    # Chaining, pipelines, redirects, nested substitutions, and compound
    # commands fall through to Claude's normal permission flow.
    name = approved_command(command)
    if name:
        # Claude Code's PreToolUse hook expects the permission decision
        # nested under hookSpecificOutput. A flat {"permissionDecision":
        # "allow"} is silently ignored and the static allow-list takes over.
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": f"macroscope-installer: auto-approve {name}",
            },
        }))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
