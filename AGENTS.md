# For agents picking up this project

You're looking at `shared-agent-memory` — a tool that keeps a coding
agent's project memory in sync across machines, instead of pinned to
wherever a session happened to start. Full design context is in
`README.md`; this file is just the "what do I do right now" entry point.

**This currently only has a Claude Code adapter.** Everything below —
the `.claude/skills/` paths, the hooks — is Claude Code-specific. If
you're a different agent, this repo's `core/` is meant to be adapter-agnostic
in principle, but nothing wires it up for you yet; see `README.md`'s
Non-goals section before assuming any of this applies as-is.

## If this repo hasn't been installed yet

Run `./install.sh` from the repo root. It creates the shared memory root
(default `~/.claude-shared-memory`) and symlinks the skills in
`.claude/skills/` into `~/.claude/skills/`, so they're available from any
session on this host afterward, not just ones launched inside this repo.

**If another host is already running `shared-agent-memory` with real
content**, don't run `install.sh` yet — pair Syncthing with that host
first. See `README.md`'s "Getting started" section for the install/pairing
steps; the `shared-agent-memory-setup` skill's step 0 covers the same
check.

## What to do next

Run the `shared-agent-memory-setup` skill
(`.claude/skills/shared-agent-memory-setup/SKILL.md`). It:

1. Confirms the shared memory root exists (creating it if `install.sh`
   wasn't run first).
2. Registers this host's `SessionStart`/`Stop` hooks.
3. Hands off to the `shared-agent-memory-migrate` skill if this host has
   existing per-project memory stores that predate this tool.

If you're being asked to work on *this repo's own code* rather than to
set it up on a host, `shared-agent-memory-setup` isn't what you want —
read `README.md` for the architecture instead.
