#!/usr/bin/env bash
# agent-incognito uninstaller — removes our files and strips only our hook
# entries from each host's config, leaving everything else alone.
set -uo pipefail

H="$HOME"
say() { printf '  %s\n' "$*"; }
command -v jq >/dev/null || { echo "agent-incognito: jq is required." >&2; exit 1; }
backup() { [[ -f "$1" ]] && cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }
strip() {  # file  jq-drop-expression
  [[ -f "$1" ]] || return 0
  jq -e . "$1" >/dev/null 2>&1 || { say "skipped $1 (not valid JSON)"; return 0; }
  backup "$1"
  local tmp; tmp="$(mktemp)"
  jq "$2" "$1" > "$tmp" && mv "$tmp" "$1"
}

NESTED='def drop_ours(a): (a // []) | map(select((([.hooks[]?.command] | join(" ")) | test("incognito\\.sh")) | not));
        if .hooks then .hooks |= with_entries(.value = drop_ours(.value))
                       | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
        else . end'
FLAT='def drop_ours(a): (a // []) | map(select(((.command // "") | test("incognito\\.sh")) | not));
      if .hooks then .hooks |= with_entries(.value = drop_ours(.value))
                     | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
      else . end'

strip "$H/.claude/settings.json" "$NESTED";  say "claude   settings.json cleaned"
strip "$H/.codex/hooks.json"     "$NESTED";  say "codex    hooks.json cleaned"
strip "$H/.cursor/hooks.json"    "$FLAT";    say "cursor   hooks.json cleaned"

rm -f  "$H/.claude/commands/incognito.md" \
       "$H/.codex/prompts/incognito.md" \
       "$H/.copilot/hooks/agent-incognito.json" \
       "$H/.copilot/instructions/agent-incognito.instructions.md"
rm -rf "$H/.cursor/skills/incognito" "$H/.agent-incognito"
# legacy paths from the Claude-only release
rm -f  "$H/.claude/hooks/incognito.sh"; rm -rf "$H/.claude/incognito"
say "commands, skills, prompts, instructions and state removed"

echo "Done. Restart each agent (Claude Code: /hooks once; Codex: /hooks) to drop the hook from running sessions."
