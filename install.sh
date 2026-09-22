#!/usr/bin/env bash
# agent-incognito installer.
#
#   ./install.sh                 install for every agent found on this machine
#   ./install.sh cursor codex    install for specific hosts
#   ./install.sh all             install for all four regardless of what's detected
#
# Hosts: claude | cursor | codex | copilot
# Works from a local copy, or over HTTPS:
#   curl -fsSL https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main/install.sh | bash
#
# Idempotent: re-running upgrades in place and never duplicates hook entries.

set -uo pipefail

HOME_DIR="$HOME"
BIN_DIR="$HOME_DIR/.agent-incognito/bin"
BIN="$BIN_DIR/incognito.sh"
RAW_BASE="${AGENT_INCOGNITO_RAW_BASE:-https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main}"

say() { printf '  %s\n' "$*"; }
die() { printf 'agent-incognito: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)."

# ---- source resolution: local checkout, else fetch on demand ----------------
SRC_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$SRC_LOCAL" && -f "$SRC_LOCAL/core/incognito.sh" ]]; then
  MODE="local copy at $SRC_LOCAL"; FETCH_DIR="$SRC_LOCAL"
else
  command -v curl >/dev/null || die "curl is required for a network install."
  MODE="$RAW_BASE"; FETCH_DIR="$(mktemp -d)"; trap 'rm -rf "$FETCH_DIR"' EXIT
fi

# fetch <repo-relative-path> -> prints an absolute path to the file
fetch() {
  local rel="$1" dst="$FETCH_DIR/$1"
  [[ -f "$dst" ]] && { printf '%s' "$dst"; return 0; }
  mkdir -p "$(dirname "$dst")"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$RAW_BASE/$rel" -o "$dst" \
    || die "download failed: $RAW_BASE/$rel"
  printf '%s' "$dst"
}

backup() { [[ -f "$1" ]] && cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }
ensure_json() {  # path default-content
  [[ -f "$1" ]] || { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
  jq -e . "$1" >/dev/null 2>&1 || die "$1 is not valid JSON — fix it first."
}
write_json() { local f="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"; mv "$tmp" "$f"; }

# ---- which hosts? ----------------------------------------------------------
TARGETS=("$@")
if ((${#TARGETS[@]} == 0)); then
  for t in claude cursor codex copilot; do
    case "$t" in
      claude)  [[ -d "$HOME_DIR/.claude"  ]] && TARGETS+=(claude) ;;
      cursor)  [[ -d "$HOME_DIR/.cursor"  ]] && TARGETS+=(cursor) ;;
      codex)   [[ -d "$HOME_DIR/.codex"   ]] && TARGETS+=(codex) ;;
      copilot) [[ -d "$HOME_DIR/.copilot" ]] && TARGETS+=(copilot) ;;
    esac
  done
  ((${#TARGETS[@]} == 0)) && die "no agent config directories found. Pass hosts explicitly: ./install.sh claude cursor codex copilot"
  echo "agent-incognito — detected: ${TARGETS[*]}"
elif [[ "${TARGETS[0]}" == "all" ]]; then
  TARGETS=(claude cursor codex copilot)
fi
echo "agent-incognito — installing from $MODE"

# ---- shared core -----------------------------------------------------------
mkdir -p "$BIN_DIR" "$HOME_DIR/.agent-incognito/state"
install -m 0755 "$(fetch core/incognito.sh)" "$BIN"
say "core                 -> $BIN"

# ---- per host --------------------------------------------------------------
for t in "${TARGETS[@]}"; do
case "$t" in

claude)
  S="$HOME_DIR/.claude/settings.json"; ensure_json "$S" '{}'; backup "$S"
  mkdir -p "$HOME_DIR/.claude/commands"
  install -m 0644 "$(fetch commands/incognito.md)" "$HOME_DIR/.claude/commands/incognito.md"
  jq --arg g "bash $BIN guard --format=claude" --arg c "bash $BIN cleanup --format=claude" '
    def drop_ours(a): (a // []) | map(select((([.hooks[]?.command] | join(" ")) | test("agent-incognito")) | not));
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = (drop_ours(.hooks.PreToolUse) + [{matcher:"Bash|Read|Edit|Write|Grep|Glob|NotebookEdit",hooks:[{type:"command",command:$g,timeout:5,statusMessage:"incognito guard"}]}])
    | .hooks.SessionEnd = (drop_ours(.hooks.SessionEnd) + [{hooks:[{type:"command",command:$c,timeout:5}]}])
  ' "$S" | write_json "$S"
  say "claude               -> /incognito command + settings.json hooks" ;;

cursor)
  S="$HOME_DIR/.cursor/hooks.json"; ensure_json "$S" '{"version":1,"hooks":{}}'; backup "$S"
  mkdir -p "$HOME_DIR/.cursor/skills/incognito"
  install -m 0644 "$(fetch cursor/skills/incognito/SKILL.md)" "$HOME_DIR/.cursor/skills/incognito/SKILL.md"
  frag="$(sed "s|\$HOME|$HOME_DIR|g" "$(fetch cursor/hooks.json)")"
  jq --argjson frag "$frag" '
    def drop_ours(a): (a // []) | map(select(((.command // "") | test("agent-incognito")) | not));
    .version = 1 | .hooks = (.hooks // {})
    | reduce ($frag.hooks | keys_unsorted[]) as $k (.; .hooks[$k] = (drop_ours(.hooks[$k]) + $frag.hooks[$k]))
  ' "$S" | write_json "$S"
  say "cursor               -> /incognito skill + ~/.cursor/hooks.json" ;;

codex)
  S="$HOME_DIR/.codex/hooks.json"; ensure_json "$S" '{"hooks":{}}'; backup "$S"
  mkdir -p "$HOME_DIR/.codex/prompts"
  install -m 0644 "$(fetch codex/prompts/incognito.md)" "$HOME_DIR/.codex/prompts/incognito.md"
  frag="$(sed "s|\$HOME|$HOME_DIR|g" "$(fetch codex/hooks.json)")"
  jq --argjson frag "$frag" '
    def drop_ours(a): (a // []) | map(select((([.hooks[]?.command] | join(" ")) | test("agent-incognito")) | not));
    .hooks = (.hooks // {})
    | reduce ($frag.hooks | keys_unsorted[]) as $k (.; .hooks[$k] = (drop_ours(.hooks[$k]) + $frag.hooks[$k]))
  ' "$S" | write_json "$S"
  say "codex                -> /incognito prompt + ~/.codex/hooks.json (needs /hooks to trust)" ;;

copilot)
  mkdir -p "$HOME_DIR/.copilot/hooks" "$HOME_DIR/.copilot/instructions"
  sed "s|\$HOME|$HOME_DIR|g" "$(fetch copilot/hooks/agent-incognito.json)" > "$HOME_DIR/.copilot/hooks/agent-incognito.json"
  install -m 0644 "$(fetch copilot/instructions/agent-incognito.instructions.md)" \
    "$HOME_DIR/.copilot/instructions/agent-incognito.instructions.md"
  say "copilot              -> hooks/agent-incognito.json + instructions" ;;

*) die "unknown host '$t' (expected: claude, cursor, codex, copilot, all)" ;;
esac
done

# ---- self-test -------------------------------------------------------------
ST="$HOME_DIR/.agent-incognito/state"; : > "$ST/s-__probe__.on"
probe='{"session_id":"__probe__","tool_name":"Read","tool_input":{"file_path":"'"$HOME_DIR"'/.claude/projects/x/memory/MEMORY.md"}}'
got="$(printf '%s' "$probe" | bash "$BIN" guard --format=claude | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
rm -f "$ST/s-__probe__.on"
[[ "$got" == "deny" ]] || die "self-test failed: guard returned '$got' for a memory path (expected deny)."
say "self-test            -> guard denies memory access when incognito is on"

cat <<'DONE'

Installed. Start a new session in each host, then:

  Claude Code   /incognito              (also: status | save | off)
  Cursor        /incognito
  Codex         /incognito  — run /hooks once first to trust the new hook
  Copilot CLI   ask it to "go incognito" (Copilot has no custom slash commands)

Uninstall with ./uninstall.sh
DONE
