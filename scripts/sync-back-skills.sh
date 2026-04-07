#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <back-repo-path> [macroscope-local-repo-path]" >&2
  exit 1
fi

BACK_REPO="$(cd "$1" && pwd)"
REPO_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

BACK_PLUGIN_ROOT="$BACK_REPO/tools/cmd/macrodaemon/public-plugin/macroscope"
PLUGIN_ROOT="$REPO_ROOT/plugins/macroscope"

if [ ! -d "$BACK_PLUGIN_ROOT" ]; then
  echo "Back public plugin root not found: $BACK_PLUGIN_ROOT" >&2
  exit 1
fi

if [ ! -d "$PLUGIN_ROOT" ]; then
  echo "Plugin destination root not found: $PLUGIN_ROOT" >&2
  exit 1
fi

rm -rf "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/host-overlays"
mkdir -p "$PLUGIN_ROOT/skills"
cp -R "$BACK_PLUGIN_ROOT/skills/macroscope" "$PLUGIN_ROOT/skills/macroscope"

if [ -d "$BACK_PLUGIN_ROOT/commands" ]; then
  cp -R "$BACK_PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands"
fi

if [ -d "$BACK_PLUGIN_ROOT/host-overlays" ]; then
  cp -R "$BACK_PLUGIN_ROOT/host-overlays" "$PLUGIN_ROOT/host-overlays"
fi

echo "Synced the public plugin tree from $BACK_REPO"
