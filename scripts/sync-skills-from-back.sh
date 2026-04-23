#!/bin/bash
set -euo pipefail

# Syncs the full plugin bundle and standalone skills from the back repo.
#
# Usage:
#   ./scripts/sync-skills-from-back.sh /path/to/back
#
# The back repo's public-plugin directory is the single source of truth.
# This script produces two things in macroscope-local:
#
#   1. The full plugin directory tree (manifests, assets, host-overlays,
#      commands) copied verbatim into .claude-plugin/ and plugins/ so
#      that marketplace submissions can point at this repo directly.
#
#   2. Standalone skills in skills/ for skills.sh cross-platform
#      distribution, with a CLI prerequisite check injected after the
#      frontmatter.

BACK_REPO="${1:?Usage: $0 /path/to/back}"
PLUGIN_ROOT="$BACK_REPO/tools/cmd/macrodaemon/public-plugin"
PLUGIN_SKILLS="$PLUGIN_ROOT/plugins/macroscope/skills"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_SKILLS="$REPO_ROOT/skills"

if [ ! -d "$PLUGIN_ROOT" ]; then
  echo "error: plugin root not found at $PLUGIN_ROOT" >&2
  exit 1
fi

# --- Part 1: Sync full plugin bundle for marketplace submissions ---

# Sync .claude-plugin/marketplace.json at repo root
mkdir -p "$REPO_ROOT/.claude-plugin"
cp "$PLUGIN_ROOT/.claude-plugin/marketplace.json" "$REPO_ROOT/.claude-plugin/marketplace.json"
echo "synced: .claude-plugin/marketplace.json"

# Sync the entire plugins/macroscope/ directory
rm -rf "$REPO_ROOT/plugins"
mkdir -p "$REPO_ROOT/plugins"
cp -R "$PLUGIN_ROOT/plugins/macroscope" "$REPO_ROOT/plugins/macroscope"
echo "synced: plugins/macroscope/"

# --- Part 2: Generate standalone skills for skills.sh ---

PREREQ_FILE="$(mktemp)"
trap 'rm -f "$PREREQ_FILE"' EXIT

cat > "$PREREQ_FILE" << 'PREREQ'
## 0. Verify the CLI is installed

```bash
command -v macroscope
```

If `macroscope` is not found, tell the user:

> Macroscope CLI is not installed. Install it with:
>
> ```bash
> curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
> ```

Stop here if the CLI is missing.
PREREQ

synced=0
for skill_dir in "$PLUGIN_SKILLS"/*/; do
  skill_name="$(basename "$skill_dir")"
  src="$skill_dir/SKILL.md"
  [ -f "$src" ] || continue

  mkdir -p "$DEST_SKILLS/$skill_name"
  dst="$DEST_SKILLS/$skill_name/SKILL.md"

  python3 -c "
import sys

with open(sys.argv[1]) as f:
    lines = f.readlines()

with open(sys.argv[2]) as f:
    prereq = f.read()

fm_closes = [i for i, l in enumerate(lines) if l.strip() == '---']
if len(fm_closes) < 2:
    sys.exit('no frontmatter found in ' + sys.argv[1])
close_idx = fm_closes[1]

body_start = close_idx + 1
while body_start < len(lines) and lines[body_start].strip() == '':
    body_start += 1

with open(sys.argv[3], 'w') as out:
    for i in range(close_idx + 1):
        out.write(lines[i])
    out.write('\n')
    out.write(prereq.rstrip('\n') + '\n')
    out.write('\n')
    for i in range(body_start, len(lines)):
        out.write(lines[i])
" "$src" "$PREREQ_FILE" "$dst"

  synced=$((synced + 1))
  echo "synced: skills/$skill_name/SKILL.md (standalone)"
done

echo "done: plugin bundle + $synced standalone skill(s) synced"
