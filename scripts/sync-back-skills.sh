#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <back-repo-path> [macroscope-local-repo-path]" >&2
  exit 1
fi

BACK_REPO="$(cd "$1" && pwd)"
REPO_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

BACK_SKILLS="$BACK_REPO/.claude/skills"
PLUGIN_SKILLS="$REPO_ROOT/plugins/macroscope/skills"

if [ ! -d "$BACK_SKILLS" ]; then
  echo "Back skills directory not found: $BACK_SKILLS" >&2
  exit 1
fi

if [ ! -d "$PLUGIN_SKILLS" ]; then
  echo "Plugin skills directory not found: $PLUGIN_SKILLS" >&2
  exit 1
fi

copy_skill() {
  local src_name="$1"
  local dst_name="$2"
  cp "$BACK_SKILLS/$src_name/SKILL.md" "$PLUGIN_SKILLS/$dst_name/SKILL.md"
}

copy_skill "macroscope" "macroscope"
copy_skill "macroscope-triage-pr-comments" "macroscope-triage-pr-comments"
copy_skill "macroscope-respond-to-pr-comments" "macroscope-respond-to-pr-comments"
copy_skill "macroscope-review-pr" "macroscope-review-pr"

python3 - "$BACK_SKILLS/macroscope-local-review/SKILL.md" "$PLUGIN_SKILLS/macroscope-local-review/SKILL.md" <<'PY'
from pathlib import Path
import sys

src_path = Path(sys.argv[1])
dst_path = Path(sys.argv[2])
text = src_path.read_text(encoding="utf-8")

def expect_replace(payload: str, old: str, new: str) -> str:
    if old not in payload:
        raise SystemExit(f"expected text not found during local-review sync:\n{old}")
    return payload.replace(old, new)

text = expect_replace(
    text,
    "description: Explicit local Macroscope review worker for the back repo. Uses the locally-built macrodaemon via `go run` when `/macroscope` delegates here.",
    "description: Explicit local Macroscope CLI review worker. Use this when the user explicitly asks for the local path, or when `/macroscope` delegates here.",
)

text = expect_replace(
    text,
    "Run a code review using the **locally-built macrodaemon** via `go run ./tools/cmd/macrodaemon`, then triage streaming issues as they arrive. This is the default workflow behind `/macroscope` in the back repo.\n\nThis is for developers working on macroscope itself. It does **not** use the installed `macroscope` binary.\n",
    "Run a code review using the installed `macroscope` CLI, then triage streaming issues as they arrive. This is the default workflow behind `/macroscope`.\n",
)

text = expect_replace(
    text,
    "\n## Environment\n\nThe default command runs against **nonprod/prod** depending on the user's `~/.macroscope/config.yaml`.\n\nTo target the Tilt dev cluster only when the user explicitly asks to review against dev/local/Tilt, prepend `--server $WORKSTATION_HOST` before the subcommand:\n\n```bash\ngo run ./tools/cmd/macrodaemon --server $WORKSTATION_HOST codereview --base <base_branch>\n```\n\nThe `--server` flag is only available in dev builds. It forces `env=local` and overrides the localagent gRPC host.\n",
    "",
)

text = expect_replace(
    text,
    "blocking `go run ./tools/cmd/macrodaemon codereview` process",
    "blocking `macroscope codereview` process",
)

text = text.replace(
    "go run ./tools/cmd/macrodaemon codereview --base <base_branch>",
    "macroscope codereview --base <base_branch>",
)
text = text.replace(
    "go run ./tools/cmd/macrodaemon codereview --status '<review_id>' 2>&1",
    "macroscope codereview --status '<review_id>' 2>&1",
)

dst_path.write_text(text, encoding="utf-8")
PY

echo "Synced packaged skills from $BACK_REPO"
