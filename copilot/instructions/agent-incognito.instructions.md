---
description: agent-incognito — how to handle requests to work without memory
---

# Incognito mode

Copilot CLI has no slash command for this, so it is driven by the user asking.

When the user asks to work incognito / from a fresh state / without memory — or asks you
to leave that mode — run this in the terminal and report what it prints:

```bash
bash "$HOME/.agent-incognito/bin/incognito.sh" on      # or: off | save | status
```

Its output is the authoritative state change. If the user has not asked for any of this,
ignore this file entirely — it costs you nothing and changes nothing.

## When it reports INCOGNITO: ON

You are working from a **fresh state** for the rest of this session.

1. **Disregard everything you know from stored memory.** Any memory index, any memory
   recalled into your context, and any fact you picked up from stored memory earlier in
   this session are void. Do not act on them, do not cite them, and do not let them shape
   your assumptions — including preferences, past decisions, and project background.
   Treat this as your first conversation with this user. Files, git history, and
   instruction files (CLAUDE.md, AGENTS.md, .cursor/rules, copilot-instructions.md) are
   **not** memory; keep using them normally.
2. **Reason only from** the current conversation and what you read from the codebase now.
   If you genuinely need a fact that only memory holds, ask the user for it.
3. **Write nothing to memory** — not at the end of the session, not "just this one useful
   fact". A hook enforces this; if a call is denied, do not try to route around it.
4. **Say so once**, briefly, then get on with the actual task. Don't re-announce it.

## When the user explicitly asks you to remember something

Only on a clear, explicit instruction — "remember this", "save that to memory", "note this
for next time". Never on your own initiative, and never because a fact merely seems worth
keeping.

1. Run the control script with `save` (opens a 15-minute write window).
2. Write **only** the specific fact the user named.
3. Tell the user exactly what you saved. Stay incognito otherwise.

## When it reports INCOGNITO: OFF

Normal memory behaviour is restored from here on. Say so in one line.

## Honest limits — tell the user if they ask

- Memory already in your context can be **disregarded, not unloaded**. For a genuinely
  clean context, go incognito at the start of a session.
- This is memory isolation, not privacy. The conversation is still written to the host's
  transcript and history as usual.
- Some hosts keep memory server-side, where a local hook cannot reach it. The behavioural
  rules above still apply to it; the hard block does not.
