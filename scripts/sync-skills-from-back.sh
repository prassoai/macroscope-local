#!/bin/bash
set -euo pipefail

# Syncs standalone skills from the back repo's base SKILL.md files,
# injecting a CLI prerequisite check (Step 0) after the frontmatter.
#
# Usage:
#   ./scripts/sync-skills-from-back.sh /path/to/back
#
# The back repo's skills/*/SKILL.md are the single source of truth.
# This script produces the skills.sh-compatible versions that live in
# this repo's skills/ directory.

BACK_REPO="${1:?Usage: $0 /path/to/back}"
PLUGIN_SKILLS="$BACK_REPO/tools/cmd/macrodaemon/public-plugin/plugins/macroscope/skills"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_SKILLS="$(cd "$SCRIPT_DIR/.." && pwd)/skills"

if [ ! -d "$PLUGIN_SKILLS" ]; then
  echo "error: plugin skills not found at $PLUGIN_SKILLS" >&2
  exit 1
fi

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

  # Strategy: find the first blank line after the closing "---" of the
  # frontmatter, and insert the prerequisite block there.
  #
  # The SKILL.md format is:
  #   ---
  #   name: ...
  #   description: ...
  #   ---
  #   <blank line>
  #   <body>
  #
  # We copy everything up to and including that blank line, insert the
  # prereq block + another blank line, then copy the rest of the body.

  python3 -c "
import sys

with open(sys.argv[1]) as f:
    lines = f.readlines()

with open(sys.argv[2]) as f:
    prereq = f.read()

# Find closing --- of frontmatter (second occurrence)
fm_closes = [i for i, l in enumerate(lines) if l.strip() == '---']
if len(fm_closes) < 2:
    sys.exit('no frontmatter found in ' + sys.argv[1])
close_idx = fm_closes[1]

# Find first blank line after frontmatter
body_start = close_idx + 1
while body_start < len(lines) and lines[body_start].strip() == '':
    body_start += 1

# Output: frontmatter + blank line + prereq + blank line + body
with open(sys.argv[3], 'w') as out:
    # Frontmatter through closing ---
    for i in range(close_idx + 1):
        out.write(lines[i])
    out.write('\n')
    out.write(prereq.rstrip('\n') + '\n')
    out.write('\n')
    # Rest of body
    for i in range(body_start, len(lines)):
        out.write(lines[i])
" "$src" "$PREREQ_FILE" "$dst"

  synced=$((synced + 1))
  echo "synced: $skill_name"
done

echo "done: $synced skill(s) synced to $DEST_SKILLS"
