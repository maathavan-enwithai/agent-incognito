# agent-incognito

An `/incognito` mode for coding agents: a state where the agent **ignores everything in
stored memory** and **writes nothing back** unless you explicitly ask it to.

Works with **Claude Code**, **Cursor**, **Codex CLI** and **GitHub Copilot CLI** — all four
expose a pre-tool hook that can deny a call, so this is enforced by the host rather than
merely requested in a prompt. When incognito is on, any tool call that reaches the memory
store is denied before it runs.

```
/incognito          # fresh state: memory is ignored, and read-only
/incognito status   # what state am I in?
/incognito save     # one-off write window — only after you asked the agent to remember something
/incognito off      # back to normal
```

---

## Why you'd want it

**Memory hygiene is the real win.** During exploratory or speculative work, wrong facts get
written as confident memories — and bad memories degrade every later answer *silently*. You
don't see the pollution; you just get worse output. A mode where writes are off by default
fixes a failure you otherwise can't detect.

Also useful for **clean-room debugging** (force the agent to reason from the code in front of
it, not a fact that went stale three migrations ago) and **borrowed context** (another
client's repo, a screen-share, a demo machine).

## What it treats as memory

Learned, recalled state — blocked while incognito:

| Host | Blocked |
|---|---|
| Claude Code | `~/.claude/projects/**/memory/`, `MEMORY.md`, all of `~/.claude/projects`, `history.jsonl` |
| Codex CLI | `~/.codex/memories_*.sqlite`, `~/.codex/sessions/`, `~/.codex/history.jsonl` |
| Cursor | `~/.cursor/projects/`, anything named `memories` |
| Copilot CLI | `~/.copilot/session-store*`, `session-state`, `sidebar-sessions-state`, `command-history-state` |

Instruction files are **not** memory and stay readable: `CLAUDE.md`, `AGENTS.md`,
`.cursor/rules`, `copilot-instructions.md`, and your repo's own files — including a
`MEMORY.md` that belongs to your project. All four hosts' stores are blocked in every host,
so a Cursor session can't read Claude Code's memory either.

The guard also blocks the sideways route: a broad `grep` over `~/.claude/projects` reaches
memory without ever naming it, so that is denied too.

---

## Host support — read this before relying on it

| | Claude Code | Codex CLI | Cursor | Copilot CLI |
|---|---|---|---|---|
| Hook denies memory access | yes | yes | yes | yes |
| Invoked by | `/incognito` | `/incognito` prompt | `/incognito` skill | ask it in words |
| Scope | one session | one session | workspace | workspace |
| Extra setup | none | `/hooks` to trust | none | none |
| Memory it *cannot* reach | — | — | server-side Memories | server-side repo memory |

Two things worth understanding:

**Scope.** Claude Code and Codex pass a session id to the hook *and* expose one to the
shell, so incognito there is scoped to exactly one session. Cursor and Copilot don't expose
a session id to the shell, so the control script falls back to keying on the **workspace** —
two Cursor windows open on the same project share one incognito state. That is a real
difference, not a rounding error.

**Server-side memory.** Cursor's Memories and Copilot's repository memory are stored on
their servers, not on your disk. A local hook cannot block what never touches the
filesystem. The behavioural half of incognito (the agent is instructed to disregard it)
still applies; the hard block does not. On Claude Code and Codex, where memory is local
files, the block is complete.

## Honest limits — all hosts

- **This is memory isolation, not privacy.** The conversation is still written to the host's
  transcript and history as usual.
- **Mid-session it's "disregard", not "unload".** Memory loaded into context at session start
  can't be pulled back out. For a genuinely clean context, go incognito at the start.
- **It guards against accidents, not against the model.** The hook cannot tell whether *you*
  asked for a save or the agent decided on its own — the agent can call `save` itself. It
  makes the safe path the default; it is not a sandbox.
- **Empty hook output is treated as "no opinion" (allow).** Verified on Claude Code by
  running it. On Cursor and Copilot this follows their documented exit-code behaviour but
  has not been confirmed against a live session — deliberately, the hooks are registered
  `failClosed: false`, so a hook problem fails open rather than blocking your work.
- **If you want memory off permanently**, you don't need this. Claude Code ships
  `"autoMemoryEnabled": false`. agent-incognito exists for the *per-session, reversible,
  with an escape hatch* case.

---

## How it works

One shared guard, four thin adapters. `core/incognito.sh` holds all the logic — state,
path matching, the allow/deny decision — and `--format=<host>` selects the response shape
that host expects (`hookSpecificOutput.permissionDecision` for Claude Code and Codex,
`permissionDecision` for Copilot, `permission` for Cursor). Session id is read from
whichever of `session_id` / `sessionId` / `conversation_id` the host sends.

State is a flag file under `~/.agent-incognito/state/`. `save` writes a 15-minute unlock
token that expires on its own, so a single "remember this" never quietly becomes a
session-long licence to write. When nothing is incognito, the guard exits before it even
parses its input.

---

## Install

Requires **bash** and **jq**. macOS and Linux (Windows: WSL or Git Bash).

```bash
curl -fsSL https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main/install.sh | bash
```

That installs for **every agent it finds** on the machine. To choose:

```bash
./install.sh cursor codex     # just these
./install.sh all              # all four regardless of what's detected
```

It writes one shared script to `~/.agent-incognito/bin/`, then per host: merges hook entries
into the host's config (keeping a timestamped backup and never touching your other hooks),
and drops in the command/skill/prompt/instruction file. Re-running upgrades in place and
never duplicates entries. It finishes by self-testing that the guard actually denies.

**Codex needs one extra step:** run `/hooks` in Codex once to review and trust the new hook.
Codex records trust against the hook's hash and skips untrusted hooks.

### Claude Code as a plugin (alternative)

The repo is also a Claude Code plugin *and* its own marketplace, so nothing is written to
your `settings.json` and updates come through `/plugin`:

```
/plugin marketplace add maathavan-enwithai/agent-incognito
/plugin install agent-incognito@agent-incognito
```

### Verify

Start a new session, run `/incognito`, then ask the agent to read a memory file. You should
see the guard's denial, not the file. `/incognito off` when you're done.

---

## Distributing it

### Without anyone cloning a repository

| Route | What the recipient runs | Good for |
|---|---|---|
| **curl installer** | the one-liner above | Any host, any machine. Detects what's installed. |
| **Claude Code plugin** | `/plugin marketplace add maathavan-enwithai/agent-incognito` | Claude Code users — managed updates, no shell. |
| **Release tarball** | `curl -fsSL https://github.com/maathavan-enwithai/agent-incognito/archive/refs/heads/main.tar.gz \| tar xz && ./agent-incognito-main/install.sh` | Pinned versions. |
| **Copy the files** | see layout below | Air-gapped or locked-down machines. |

### Push it to a whole team

**Claude Code** — commit to a repo's `.claude/settings.json` and every teammate who opens it
gets the plugin, with nothing to run:

```json
{
  "extraKnownMarketplaces": {
    "agent-incognito": { "source": { "source": "github", "repo": "maathavan-enwithai/agent-incognito" } }
  },
  "enabledPlugins": { "agent-incognito@agent-incognito": true }
}
```

Pin a version with `"ref": "v1.0.0"`. Swap the source for an internal host, npm package, or
a shared directory — `{"source":"directory","path":"/opt/shared/agent-incognito"}` is the
air-gapped answer and touches no network.

**Cursor and Codex** both read project-level hook config, so committing `.cursor/hooks.json`
or `.codex/hooks.json` to a repo applies the guard to everyone working in it. **Copilot**
reads `.github/hooks/NAME.json` from the repository the same way.

**Enterprise** — Claude Code and Cursor both support machine-wide managed hook config
(`/Library/Application Support/{ClaudeCode,Cursor}/` on macOS, `/etc/{claude-code,cursor}/`
on Linux). Codex treats managed hooks as trusted by policy, which also skips the `/hooks`
trust step for your users.

---

## Uninstall

`./uninstall.sh` — strips only its own hook entries from each host's config, leaving your
other hooks alone, and removes every file it installed. Timestamped backups are kept.
Claude Code plugin installs: `/plugin uninstall agent-incognito@agent-incognito`.

## Layout

```
agent-incognito/
├── core/incognito.sh            # the whole implementation: state, matching, decision
├── .claude-plugin/              # plugin + marketplace manifests (Claude Code)
├── commands/incognito.md        # Claude Code slash command
├── hooks/hooks.json             # Claude Code hook registration (plugin installs)
├── cursor/
│   ├── hooks.json               # merged into ~/.cursor/hooks.json
│   └── skills/incognito/SKILL.md
├── codex/
│   ├── hooks.json               # merged into ~/.codex/hooks.json
│   └── prompts/incognito.md
├── copilot/
│   ├── hooks/agent-incognito.json
│   └── instructions/agent-incognito.instructions.md
├── install.sh                   # multi-host, local or over HTTPS
└── uninstall.sh
```

## Troubleshooting

**The command doesn't appear.** Start a new session. Claude Code only watches directories
that had a settings file when the session started.

**The hook doesn't fire.** Claude Code: `/hooks` once, or restart. Codex: `/hooks` to trust
it — an untrusted hook is skipped silently. Cursor/Copilot: restart the app.

**Everything is being denied.** Test the guard directly — it should print nothing (allow):

```bash
echo '{"session_id":"x","tool_name":"Read","tool_input":{"file_path":"/tmp/a.ts"}}' \
  | bash ~/.agent-incognito/bin/incognito.sh guard --format=claude
```

**Cursor blocks everything after installing.** That would mean Cursor counts a silent hook
as an invalid permission response. Make the guard answer out loud instead:

```bash
export AGENT_INCOGNITO_EXPLICIT_ALLOW=1
```

It is off by default because an explicit `allow` also waves past Cursor's own approval
prompts — only turn it on if you hit the problem.

**Clear a stuck flag.** `rm -f ~/.agent-incognito/state/*.on`

**`jq: command not found` in the hook.** The guard needs `jq` on the PATH the host launches
hooks with. `brew install jq` / `apt install jq`.
