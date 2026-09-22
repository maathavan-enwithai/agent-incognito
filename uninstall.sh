#!/usr/bin/env bash
# agent-incognito uninstaller — reverses install.sh. Leaves a settings.json backup.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq >/dev/null || { echo "agent-incognito: jq is required." >&2; exit 1; }

rm -f "$CLAUDE_DIR/commands/incognito.md" "$CLAUDE_DIR/hooks/incognito.sh"
rm -rf "$CLAUDE_DIR/incognito"
echo "  removed command, hook script and session state"

if [[ -f "$SETTINGS" ]] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  tmp="$(mktemp)"
  jq '
    def drop_ours:
      map(select((([.hooks[]?.command] | join(" ")) | test("incognito\\.sh")) | not));
    if .hooks then
      .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) | drop_ours)
    | .hooks.SessionEnd  = ((.hooks.SessionEnd  // []) | drop_ours)
    | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
    else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "  settings.json cleaned (backup: $(basename "$BACKUP"))"
fi

echo "Done. Restart Claude Code, or run /hooks once, to drop the hook from the running session."
