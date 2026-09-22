#!/usr/bin/env bash
# agent-incognito installer — manual (non-plugin) install into ~/.claude.
#
#   From a local copy:   ./install.sh
#   Without any copy:    curl -fsSL https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main/install.sh | bash
#   From a fork:         ... | AGENT_INCOGNITO_RAW_BASE=<your raw base> bash
#
# Idempotent: re-running upgrades in place and never duplicates the hook entries.
# Prefer the plugin install (see README) if you want managed updates.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RAW_BASE="${AGENT_INCOGNITO_RAW_BASE:-https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main}"

say()  { printf '  %s\n' "$*"; }
die()  { printf 'agent-incognito: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)."

# ---- locate sources: local checkout if present, otherwise fetch over HTTPS ---
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$SRC" && -f "$SRC/hooks/incognito.sh" && -f "$SRC/commands/incognito.md" ]]; then
  MODE="local copy at $SRC"
else
  command -v curl >/dev/null || die "curl is required for a network install."
  SRC="$(mktemp -d)"; trap 'rm -rf "$SRC"' EXIT
  mkdir -p "$SRC/hooks" "$SRC/commands"
  curl -fsSL "$RAW_BASE/hooks/incognito.sh"   -o "$SRC/hooks/incognito.sh"   || die "download failed: $RAW_BASE/hooks/incognito.sh"
  curl -fsSL "$RAW_BASE/commands/incognito.md" -o "$SRC/commands/incognito.md" || die "download failed: $RAW_BASE/commands/incognito.md"
  MODE="$RAW_BASE"
fi

echo "agent-incognito — installing from $MODE"

# ---- files -----------------------------------------------------------------
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/incognito"
install -m 0755 "$SRC/hooks/incognito.sh"    "$CLAUDE_DIR/hooks/incognito.sh"
install -m 0644 "$SRC/commands/incognito.md" "$CLAUDE_DIR/commands/incognito.md"
say "hooks/incognito.sh    -> $CLAUDE_DIR/hooks/"
say "commands/incognito.md -> $CLAUDE_DIR/commands/"

# ---- settings.json ---------------------------------------------------------
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
jq -e . "$SETTINGS" >/dev/null || die "$SETTINGS is not valid JSON — fix it first; a broken settings file disables every setting in it."

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

# Keep the portable "$HOME/.claude" spelling when that is where we installed,
# so the same settings.json works on another machine; otherwise pin the real path.
if [[ "$CLAUDE_DIR" == "$HOME/.claude" ]]; then HOOK_CMD='$HOME/.claude/hooks/incognito.sh'; else HOOK_CMD="$CLAUDE_DIR/hooks/incognito.sh"; fi
PRE="$(jq -nc --arg c "$HOOK_CMD guard"   '{matcher:"Bash|Read|Edit|Write|Grep|Glob|NotebookEdit",hooks:[{type:"command",command:$c,timeout:5,statusMessage:"incognito guard"}]}')"
END="$(jq -nc --arg c "$HOOK_CMD cleanup" '{hooks:[{type:"command",command:$c,timeout:5}]}')"

tmp="$(mktemp)"
jq --argjson pre "$PRE" --argjson end "$END" '
  def drop_ours:
    map(select((([.hooks[]?.command] | join(" ")) | test("incognito\\.sh")) | not));
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (((.hooks.PreToolUse // []) | drop_ours) + [$pre])
  | .hooks.SessionEnd = (((.hooks.SessionEnd // []) | drop_ours) + [$end])
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

say "settings.json        -> PreToolUse + SessionEnd hooks registered (backup: $(basename "$BACKUP"))"

# ---- verify ----------------------------------------------------------------
probe='{"session_id":"__probe__","tool_name":"Read","tool_input":{"file_path":"'"$CLAUDE_DIR"'/projects/x/memory/MEMORY.md"}}'
: > "$CLAUDE_DIR/incognito/__probe__.on"
got="$(printf '%s' "$probe" | "$CLAUDE_DIR/hooks/incognito.sh" guard | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
rm -f "$CLAUDE_DIR/incognito/__probe__.on"
[[ "$got" == "deny" ]] || die "self-test failed: guard returned '$got' for a memory path (expected deny)."
say "self-test            -> guard denies memory access when incognito is on"

cat <<'DONE'

Installed. Open a new Claude Code session (or run /hooks once to reload config), then:

  /incognito          start a fresh state — stored memory is ignored and read-only
  /incognito status   check the current state
  /incognito save     one-off unlock, only when you have asked Claude to remember something
  /incognito off      back to normal

Uninstall with ./uninstall.sh
DONE
