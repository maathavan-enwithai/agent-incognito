# agent-incognito

A `/incognito` mode for Claude Code: a per-session state where Claude **ignores everything
in stored memory** and **writes nothing back** unless you explicitly ask it to.

Unlike a prompt that asks Claude to "please ignore your memory", this is enforced by a
`PreToolUse` hook. When incognito is on, any tool call that reaches the memory store is
denied by the harness before it runs.

```
/incognito          # fresh state: memory is ignored, and read-only
/incognito status   # what state am I in?
/incognito save     # one-off write window — only after you asked Claude to remember something
/incognito off      # back to normal
```

---

## Why you'd want it

**Memory hygiene is the real win.** During exploratory or speculative work, wrong facts get
written as confident memories — and bad memories degrade every later answer *silently*. You
don't see the pollution; you just get worse output. A mode where writes are off by default
fixes a failure you otherwise can't detect.

Also useful for:

- **Clean-room debugging** — force Claude to reason from the code in front of it, instead of
  a remembered fact that went stale three migrations ago.
- **Borrowed context** — another client's repo, a screen-share, a demo machine.

## Honest limits — please read before you rely on it

- **This is memory isolation, not privacy.** The conversation is still written to the session
  transcript and `history.jsonl` as usual. If privacy is what you want, the levers are
  `--no-session-persistence` and `cleanupPeriodDays`, not this.
- **Mid-session it's "disregard", not "unload".** `MEMORY.md` is loaded into context at session
  start; no command can pull it back out. For a genuinely clean context, go incognito at the
  start of a session or right after `/clear`.
- **It guards against accidents, not against the model.** The hook cannot tell whether *you*
  asked for a save or Claude decided on its own — Claude can call `save` itself. It makes the
  safe path the default; it is not a sandbox.
- **If you want memory off permanently**, you don't need this at all. Claude Code ships
  `"autoMemoryEnabled": false`, which disables memory for a project outright. agent-incognito
  exists for the *per-session, reversible, with an escape hatch* case.

---

## How it works

Three moving parts:

| Part | Does what |
|---|---|
| `commands/incognito.md` | The `/incognito` slash command. Flips state, and instructs Claude how to behave in a fresh state. |
| `hooks/incognito.sh` | Control script **and** the `PreToolUse` guard. One file, two modes. |
| `hooks/hooks.json` | Registers the guard on `Bash\|Read\|Edit\|Write\|Grep\|Glob\|NotebookEdit`, plus a `SessionEnd` cleanup. |

State is a flag file at `~/.claude/incognito/<session-id>.on`, so **scope is one session**.
Other sessions you have open are unaffected, and a `SessionEnd` hook clears the flag when the
session ends.

What the guard blocks while incognito is on, whether it arrives via `Read`, `Grep`, `Glob`, or a
`Bash` command:

- the auto-memory directory and `MEMORY.md`
- `~/.claude/projects/**` — because a broad grep there reaches memory without ever naming it
- `~/.claude/history.jsonl` — cross-session prompt history
- a custom `autoMemoryDirectory`, if you have one configured

It does **not** touch your repo's own files, including a `MEMORY.md` that belongs to your project.
When nothing is incognito, the guard exits before it even parses its input.

`/incognito save` writes a 15-minute unlock token. The guard honours it, then it expires on its
own — so a single "remember this" never quietly becomes a session-long licence to write.

---

## Install

Requires **bash** and **jq**. macOS and Linux. (Windows: WSL or Git Bash.)

### Option 1 — as a plugin (recommended)

The folder is both a plugin *and* a single-plugin marketplace, so a Git host is all you need.
**The user never clones anything** — Claude Code fetches it:

```
/plugin marketplace add maathavan-enwithai/agent-incognito
/plugin install agent-incognito@agent-incognito
```

Updates come through `/plugin`, and uninstalling is `/plugin uninstall`. Nothing is written to
your `settings.json`.

### Option 2 — one-line installer, no git at all

```bash
curl -fsSL https://raw.githubusercontent.com/maathavan-enwithai/agent-incognito/main/install.sh | bash
```

Installing from a fork? Point it at your own copy with
`| AGENT_INCOGNITO_RAW_BASE=<your raw base> bash`.

Fetches the two files, drops them in `~/.claude/`, merges the hooks into `settings.json`
(backup kept), and runs a self-test that the guard actually denies. Re-running upgrades in
place and never duplicates hook entries.

From a local copy, the same script works with no network and no env var: `./install.sh`

### Option 3 — fully manual, no network

The whole tool is two files. Copy them, then register the hooks:

```bash
mkdir -p ~/.claude/commands ~/.claude/hooks
cp commands/incognito.md ~/.claude/commands/
cp hooks/incognito.sh    ~/.claude/hooks/ && chmod +x ~/.claude/hooks/incognito.sh

jq '.hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
      matcher: "Bash|Read|Edit|Write|Grep|Glob|NotebookEdit",
      hooks: [{type:"command", command:"$HOME/.claude/hooks/incognito.sh guard", timeout:5}]}])
  | .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{
      hooks: [{type:"command", command:"$HOME/.claude/hooks/incognito.sh cleanup", timeout:5}]}])' \
  ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Both files are short and readable — for an air-gapped machine, pasting them by hand is a
perfectly reasonable install path.

### Verify

Open a new session (or run `/hooks` once to reload config), then:

```
/incognito
```

Ask Claude to read a memory file. You should see the guard's denial, not the file.
`/incognito off` when you're done.

---

## Distributing it to other people

### Without anyone cloning a repository

| Route | What the recipient runs | Good for |
|---|---|---|
| **Plugin marketplace** | `/plugin marketplace add maathavan-enwithai/agent-incognito` | Most people. Managed updates, no shell, no settings edits. |
| **curl installer** | the one-liner in Option 2 | CI images, dotfiles bootstraps, anyone without `/plugin`. |
| **Release tarball** | `curl -fsSL https://github.com/maathavan-enwithai/agent-incognito/archive/refs/heads/main.tar.gz \| tar xz && ./agent-incognito-main/install.sh` | Pinned versions, offline-ish installs. |
| **Two files** | copy/paste per Option 3 | Air-gapped or locked-down machines. |
| **npm** | publish, then use an npm plugin source (below) | Teams already standardised on npm. |

### Push it to a whole team automatically

Commit this to a repo's `.claude/settings.json` and every teammate who opens that repo gets the
plugin — no instructions to follow, nothing to run:

```json
{
  "extraKnownMarketplaces": {
    "agent-incognito": { "source": { "source": "github", "repo": "maathavan-enwithai/agent-incognito" } }
  },
  "enabledPlugins": { "agent-incognito@agent-incognito": true }
}
```

Pin a version with `"ref": "v1.0.0"` inside the source object.

### Internal Git host, npm, or a shared directory

Swap the marketplace source; everything else is identical:

```json
{ "source": "git",       "url": "https://git.internal.example.com/tools/agent-incognito.git" }
{ "source": "npm",       "package": "@yourorg/agent-incognito" }
{ "source": "directory", "path": "/opt/shared/agent-incognito" }
{ "source": "git-subdir","url": "https://github.com/your-org/monorepo", "path": "tools/agent-incognito" }
```

`directory` is the air-gapped answer: drop the folder on a shared mount or ship it with your
machine image, and point `extraKnownMarketplaces` at the path. No network is touched.

### Enterprise rollout

Put the same `extraKnownMarketplaces` + `enabledPlugins` block in **managed settings**
(`/Library/Application Support/ClaudeCode/managed-settings.json` on macOS,
`/etc/claude-code/managed-settings.json` on Linux). It applies to every user and can't be
disabled locally. If your org sets `strictKnownMarketplaces`, add this source to that list too,
or the install is refused before anything downloads.

---

## Uninstall

- Plugin install: `/plugin uninstall agent-incognito@agent-incognito`
- Manual install: `./uninstall.sh` — removes both files and strips only its own hook entries
  from `settings.json`, leaving your other hooks alone. A timestamped backup is kept.

---

## Layout

```
agent-incognito/
├── .claude-plugin/
│   ├── plugin.json         # plugin manifest
│   └── marketplace.json    # lets the repo serve as its own marketplace
├── commands/incognito.md   # the /incognito slash command
├── hooks/
│   ├── hooks.json          # hook registration (plugin installs)
│   └── incognito.sh        # control script + PreToolUse guard
├── install.sh              # manual install, local or over HTTPS
└── uninstall.sh
```

## Troubleshooting

**`/incognito` doesn't appear.** Start a new session. For manual installs, Claude Code only
watches directories that had a settings file when the session started.

**The hook doesn't fire.** Run `/hooks` once to reload config, or restart. Check the entry
survived with `jq '.hooks.PreToolUse' ~/.claude/settings.json`.

**Everything is being denied.** Test the guard directly — it should print nothing for a normal file:

```bash
echo '{"session_id":"x","tool_name":"Read","tool_input":{"file_path":"/tmp/a.ts"}}' \
  | bash ~/.claude/hooks/incognito.sh guard
```

**Clear a stuck flag.** `rm -f ~/.claude/incognito/*.on`

**`jq: command not found` in the hook.** The guard needs `jq` on the `PATH` that Claude Code
launches hooks with. `brew install jq` or `apt install jq`.
