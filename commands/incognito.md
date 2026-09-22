---
description: Work from a fresh state — ignore all stored memory, and save nothing unless explicitly told to
argument-hint: "[on | off | save | status]"
allowed-tools: Bash(sh:*)
---

!`sh -c 'p="${CLAUDE_PLUGIN_ROOT:-}/hooks/incognito.sh"; [ -f "$p" ] || p="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/incognito.sh"; exec bash "$p" "$@"' -- $ARGUMENTS`

The line above is the authoritative state change. Act on whichever state it reports.

## When it reports INCOGNITO: ON

You are working from a **fresh state** for the rest of this session.

1. **Disregard everything you know from stored memory.** Any `MEMORY.md` index, any
   memory recalled in a `<system-reminder>`, and any fact you picked up from stored
   memory earlier in this session are now void. Do not act on them, do not cite them,
   and do not let them shape your assumptions — including preferences, past decisions,
   and project background. Treat this as your first conversation with this user.
   Files, git history, and `CLAUDE.md` are **not** memory; keep using them normally.
2. **Reason only from** the current conversation and what you read from the codebase now.
   If you genuinely need a fact that only memory holds, ask the user for it.
3. **Write nothing to memory.** No new memory files, no `MEMORY.md` edits — not at the
   end of the session, not "just this one useful fact". A hook enforces this; if a call
   is denied, do not try to route around it.
4. **Say so once**, briefly, then get on with the actual task. Don't re-announce it.

## When the user explicitly asks you to remember something

Only on a clear, explicit instruction — "remember this", "save that to memory",
"note this for next time". Never on your own initiative, and never because a fact
merely seems worth keeping.

1. Run `/incognito save` (opens a 15-minute write window).
2. Write **only** the specific fact the user named, in the normal memory format.
3. Tell the user exactly what you saved. Stay incognito otherwise.

## When it reports INCOGNITO: OFF

Normal memory behaviour is restored from here on. Say so in one line.

## Honest limits — tell the user if they ask

- Memory already in your context can be **disregarded, not unloaded**. For a guaranteed
  clean context, start incognito at the beginning of a session (or right after `/clear`).
- This is memory isolation, not privacy. The conversation is still written to the
  session transcript and `history.jsonl` as usual.
- Scope is this session only, keyed by session id. Other open sessions are unaffected.
