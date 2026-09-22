#!/usr/bin/env bash
# incognito.sh — per-session memory isolation for Claude Code.
#
#   incognito.sh on|off|save|status   -> control (run from inside a Claude session)
#   incognito.sh guard                -> PreToolUse hook (reads hook JSON on stdin)
#   incognito.sh cleanup              -> SessionEnd hook (clears this session's state)
#
# State lives in ~/.claude/incognito/<session-id>.{on,unlock}, so concurrent
# sessions never affect each other. Works identically whether this file sits in
# ~/.claude/hooks/ (manual install) or inside a plugin root (plugin install).

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="$CLAUDE_DIR/incognito"
SETTINGS="$CLAUDE_DIR/settings.json"
UNLOCK_SECONDS=900   # how long an explicit "save" keeps memory writable

mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------- helpers ---

# Does $1 reach anything Claude Code treats as remembered state?
is_memory_path() {
  local s="$1"
  [[ -z "$s" ]] && return 1
  # Anything under .claude that reaches auto-memory, the per-project store that
  # holds it, or the cross-session prompt history. /projects is included on
  # purpose: a broad grep there reaches memory without ever naming it.
  if [[ "$s" == *".claude"* ]] && { [[ "$s" == *"/memory"* ]] || [[ "$s" == *"MEMORY.md"* ]] \
      || [[ "$s" == *"/projects"* ]] || [[ "$s" == *"history.jsonl"* ]]; }; then
    return 0
  fi
  # Honour a custom autoMemoryDirectory if one is configured.
  local custom
  custom=$(jq -r '.autoMemoryDirectory // empty' "$SETTINGS" 2>/dev/null)
  if [[ -n "$custom" ]]; then
    custom="${custom/#\~/$HOME}"
    [[ "$s" == *"$custom"* ]] && return 0
  fi
  return 1
}

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --------------------------------------------------------------- hook mode ---

if [[ "${1:-}" == "guard" ]]; then
  # Fast path: nothing is incognito anywhere -> get out before touching stdin.
  shopt -s nullglob
  flags=("$STATE_DIR"/*.on)
  ((${#flags[@]} == 0)) && exit 0

  payload=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
  [[ -z "$sid" ]] && exit 0
  [[ -f "$STATE_DIR/$sid.on" ]] || exit 0

  # Everything the tool might point at: paths, bash command text, glob patterns.
  target=$(jq -r '[.tool_input.file_path?, .tool_input.notebook_path?, .tool_input.path?,
                   .tool_input.pattern?, .tool_input.command?, .tool_input.glob?]
                  | map(select(. != null and . != "")) | join(" ")' <<<"$payload" 2>/dev/null)

  is_memory_path "$target" || exit 0

  # Explicitly unlocked by the user? Allow, silently.
  unlock="$STATE_DIR/$sid.unlock"
  if [[ -f "$unlock" ]]; then
    expiry=$(cat "$unlock" 2>/dev/null)
    if [[ "$expiry" =~ ^[0-9]+$ ]] && (( $(date +%s) < expiry )); then
      exit 0
    fi
    rm -f "$unlock"
  fi

  deny "Incognito mode is ON for this session: stored memory is off limits, for reads and writes alike. Do not retry, and do not look for another route to this path. If the user has explicitly asked you to remember or recall something, run '$0 save' first, then retry. '/incognito off' leaves incognito entirely."
fi

# ------------------------------------------------------------ cleanup mode ---

if [[ "${1:-}" == "cleanup" ]]; then
  sid=$(jq -r '.session_id // empty' 2>/dev/null)
  [[ -n "$sid" ]] && rm -f "$STATE_DIR/$sid.on" "$STATE_DIR/$sid.unlock"
  exit 0
fi

# ------------------------------------------------------------ control mode ---

SID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -z "$SID" ]]; then
  echo "incognito: CLAUDE_CODE_SESSION_ID is not set — this must be run from inside a Claude Code session." >&2
  exit 1
fi
FLAG="$STATE_DIR/$SID.on"
UNLOCK="$STATE_DIR/$SID.unlock"

case "${1:-on}" in
  on|ON)
    date +%s > "$FLAG"
    rm -f "$UNLOCK"
    echo "INCOGNITO: ON (session $SID). Stored-memory reads and writes are now blocked by hook."
    ;;
  off|OFF)
    rm -f "$FLAG" "$UNLOCK"
    echo "INCOGNITO: OFF (session $SID). Normal memory behaviour restored."
    ;;
  save)
    if [[ ! -f "$FLAG" ]]; then
      echo "INCOGNITO: not active — memory is already writable, no unlock needed."
      exit 0
    fi
    echo $(( $(date +%s) + UNLOCK_SECONDS )) > "$UNLOCK"
    echo "INCOGNITO: memory unlocked for ${UNLOCK_SECONDS}s by explicit user request. Write the memory now."
    ;;
  status)
    if [[ -f "$FLAG" ]]; then
      echo "INCOGNITO: ON (since $(date -r "$(cat "$FLAG")" '+%H:%M:%S' 2>/dev/null))"
      if [[ -f "$UNLOCK" ]]; then
        exp=$(cat "$UNLOCK")
        (( $(date +%s) < exp )) && echo "  memory write window open for $(( exp - $(date +%s) ))s"
      fi
    else
      echo "INCOGNITO: OFF"
    fi
    ;;
  *)
    echo "usage: incognito.sh {on|off|save|status}" >&2; exit 1 ;;
esac
