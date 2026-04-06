#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <back-repo-path> [macroscope-local-repo-path]" >&2
  exit 1
fi

BACK_REPO="$(cd "$1" && pwd)"
REPO_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

BACK_SKILL="$BACK_REPO/tools/cmd/macrodaemon/public-plugin/macroscope/skills/macroscope/SKILL.md"
PLUGIN_SKILL="$REPO_ROOT/plugins/macroscope/skills/macroscope/SKILL.md"

if [ ! -f "$BACK_SKILL" ]; then
  echo "Back public plugin skill not found: $BACK_SKILL" >&2
  exit 1
fi

if [ ! -f "$PLUGIN_SKILL" ]; then
  echo "Plugin skill destination not found: $PLUGIN_SKILL" >&2
  exit 1
fi

cp "$BACK_SKILL" "$PLUGIN_SKILL"

echo "Overlaid the public plugin skill from $BACK_REPO"
