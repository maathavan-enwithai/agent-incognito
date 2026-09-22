#!/usr/bin/env bash
# agent-incognito — per-session memory isolation, shared across coding agents.
#
#   incognito.sh on|off|save|status        control (run from inside an agent session)
#   incognito.sh guard   --format=FORMAT   pre-tool hook; reads the hook payload on stdin
#   incognito.sh cleanup --format=FORMAT   session-end hook; clears that session's state
#
# FORMAT selects the host's hook contract: claude | codex | cursor | copilot.
# Everything else — where state lives, what counts as memory — is shared.

set -uo pipefail

STATE_DIR="$HOME/.agent-incognito/state"
UNLOCK_SECONDS=900
mkdir -p "$STATE_DIR" 2>/dev/null

FORMAT="claude"
for a in "$@"; do case "$a" in --format=*) FORMAT="${a#--format=}" ;; esac; done

# ---------------------------------------------------------------- state keys ---
# Claude Code exposes a session id to the shell, so incognito there is scoped to
# exactly one session. The others don't, so they fall back to the workspace.
ws_key() { printf 'w%s' "$(printf '%s' "$1" | tr '/' '-')"; }

control_key() {
  if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then printf 's-%s' "$CLAUDE_CODE_SESSION_ID"
  else ws_key "$PWD"; fi
}

# ------------------------------------------------------------ what is memory ---
# Learned/recalled state is memory. Instruction files (CLAUDE.md, AGENTS.md,
# .cursor/rules, copilot-instructions.md) are not — they are project config, and
# stay readable in incognito.
is_memory_path() {
  local s="$1"
  [[ -z "$s" ]] && return 1

  # Claude Code: auto-memory, the per-project store holding it, prompt history.
  # /projects is included on purpose — a broad grep there reaches memory
  # without ever naming it.
  if [[ "$s" == *".claude"* ]] && { [[ "$s" == *"/memory"* ]] || [[ "$s" == *"MEMORY.md"* ]] \
      || [[ "$s" == *"/projects"* ]] || [[ "$s" == *"history.jsonl"* ]]; }; then return 0; fi

  # Codex: memories_*.sqlite, rollout sessions, prompt history.
  if [[ "$s" == *".codex"* ]] && { [[ "$s" == *"memories"* ]] || [[ "$s" == *"/sessions"* ]] \
      || [[ "$s" == *"history.jsonl"* ]]; }; then return 0; fi

  # Cursor: per-project agent state and memories.
  if [[ "$s" == *".cursor"* ]] && { [[ "$s" == *"/projects"* ]] || [[ "$s" == *"memories"* ]]; }; then return 0; fi

  # Copilot CLI: session stores and command history.
  if [[ "$s" == *".copilot"* ]] && { [[ "$s" == *"session-store"* ]] || [[ "$s" == *"session-state"* ]] \
      || [[ "$s" == *"sessions-state"* ]] || [[ "$s" == *"command-history"* ]]; }; then return 0; fi

  # A custom Claude Code autoMemoryDirectory, if one is configured.
  local custom
  custom=$(jq -r '.autoMemoryDirectory // empty' "$HOME/.claude/settings.json" 2>/dev/null)
  if [[ -n "$custom" ]]; then
    custom="${custom/#\~/$HOME}"
    [[ "$s" == *"$custom"* ]] && return 0
  fi
  return 1
}

REASON="Incognito mode is ON for this session: stored memory is off limits, for reads and writes alike. Do not retry, and do not look for another route to this path. If the user has explicitly asked you to remember or recall something, run 'incognito.sh save' first, then retry. Turn incognito off to leave it entirely."

emit_deny() {
  case "$FORMAT" in
    cursor)
      jq -nc --arg r "$REASON" '{permission:"deny",user_message:"agent-incognito: memory access blocked",agent_message:$r}' ;;
    copilot)
      jq -nc --arg r "$REASON" '{permissionDecision:"deny",permissionDecisionReason:$r}' ;;
    *) # claude, codex — identical contract
      jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
  esac
  exit 0
}

# --------------------------------------------------------------- hook modes ---
if [[ "${1:-}" == "guard" ]]; then
  shopt -s nullglob
  flags=("$STATE_DIR"/*.on)
  ((${#flags[@]} == 0)) && exit 0           # nothing incognito anywhere: cheapest exit

  payload=$(cat)

  sid=$(jq -r '.session_id // .sessionId // .conversation_id // empty' <<<"$payload" 2>/dev/null)
  cwd=$(jq -r '.cwd // (.workspace_roots[0]? // empty) // empty' <<<"$payload" 2>/dev/null)

  key=""
  [[ -n "$sid" && -f "$STATE_DIR/s-$sid.on" ]] && key="s-$sid"
  if [[ -z "$key" && -n "$cwd" ]]; then
    w=$(ws_key "$cwd"); [[ -f "$STATE_DIR/$w.on" ]] && key="$w"
  fi
  [[ -z "$key" ]] && exit 0                 # this session isn't incognito

  # Every field a host might put a path or command in. .cwd is deliberately
  # excluded — matching on it would deny every tool call from that directory.
  target=$(jq -r '[ .tool_input?, .toolArgs?, .tool_input?.file_path?, .tool_input?.command?,
                    .tool_input?.path?, .tool_input?.pattern?, .tool_input?.notebook_path?,
                    .tool_input?.glob?, .file_path?, .command?, .path?, .attachments? ]
                  | map(select(. != null))
                  | map(if type == "string" then . else tojson end) | join(" ")' <<<"$payload" 2>/dev/null)

  if ! is_memory_path "$target"; then
    # Allowing = staying silent, so the host applies its own policy. Cursor's docs
    # say a permission hook returning invalid JSON blocks the action; if empty
    # output ever turns out to count as invalid there, set
    # AGENT_INCOGNITO_EXPLICIT_ALLOW=1 to answer "allow" out loud instead. Off by
    # default: an explicit allow would also wave past the host's own approval prompts.
    if [[ "$FORMAT" == "cursor" && "${AGENT_INCOGNITO_EXPLICIT_ALLOW:-}" == "1" ]]; then
      printf '{"permission":"allow"}\n'
    fi
    exit 0
  fi

  unlock="$STATE_DIR/$key.unlock"
  if [[ -f "$unlock" ]]; then
    expiry=$(cat "$unlock" 2>/dev/null)
    if [[ "$expiry" =~ ^[0-9]+$ ]] && (( $(date +%s) < expiry )); then exit 0; fi
    rm -f "$unlock"
  fi

  emit_deny
fi

if [[ "${1:-}" == "cleanup" ]]; then
  payload=$(cat 2>/dev/null)
  sid=$(jq -r '.session_id // .sessionId // .conversation_id // empty' <<<"$payload" 2>/dev/null)
  [[ -n "$sid" ]] && rm -f "$STATE_DIR/s-$sid.on" "$STATE_DIR/s-$sid.unlock"
  exit 0
fi

# ------------------------------------------------------------ control mode ---
KEY="$(control_key)"
FLAG="$STATE_DIR/$KEY.on"
UNLOCK="$STATE_DIR/$KEY.unlock"
if [[ "$KEY" == s-* ]]; then SCOPE="session ${KEY#s-}"; else SCOPE="workspace $PWD"; fi

case "${1:-on}" in
  on|ON)
    date +%s > "$FLAG"; rm -f "$UNLOCK"
    echo "INCOGNITO: ON ($SCOPE). Stored-memory reads and writes are now blocked by hook." ;;
  off|OFF)
    rm -f "$FLAG" "$UNLOCK"
    echo "INCOGNITO: OFF ($SCOPE). Normal memory behaviour restored." ;;
  save)
    [[ -f "$FLAG" ]] || { echo "INCOGNITO: not active — memory is already writable, no unlock needed."; exit 0; }
    echo $(( $(date +%s) + UNLOCK_SECONDS )) > "$UNLOCK"
    echo "INCOGNITO: memory unlocked for ${UNLOCK_SECONDS}s by explicit user request. Write the memory now." ;;
  status)
    if [[ -f "$FLAG" ]]; then
      echo "INCOGNITO: ON ($SCOPE)"
      if [[ -f "$UNLOCK" ]]; then
        exp=$(cat "$UNLOCK"); (( $(date +%s) < exp )) && echo "  memory write window open for $(( exp - $(date +%s) ))s"
      fi
    else echo "INCOGNITO: OFF ($SCOPE)"; fi ;;
  *) echo "usage: incognito.sh {on|off|save|status}" >&2; exit 1 ;;
esac
