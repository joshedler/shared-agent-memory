---
name: shared-agent-memory-setup
description: One-time setup for shared-agent-memory on this host — creates the shared memory root, registers the Claude Code hooks, and hands off to migration for any pre-existing memory stores.
---

# shared-agent-memory: setup

Run this once per host, the first time `shared-agent-memory` is installed
there. Safe to re-run — every step below should no-op if it's already done.

## 0. If this isn't the first host, pair Syncthing first

Ask the user whether another host is already running `shared-agent-memory`
with real content in its shared root. If so, and Syncthing isn't already
paired and syncing between this host and that one, stop here and point
them at `README.md`'s "Getting started" section (the "Each additional
host" part) to install and pair Syncthing first — don't continue to step 1
yet. Confirm the shared root here already shows synced content (folder
"Up to Date" in Syncthing's GUI, real files already present) before moving
on. If this genuinely is the first host, skip straight to step 1.

**Why this order matters:** step 3's migration compares this host's own
pre-existing memory against whatever's already at each shared-root key. If
nothing's synced in yet, migration only has this host's own content to
work with, and a real cross-host merge (e.g. two independently-built
`_personal` stores) can't happen properly — it gets treated as fresh
content instead of something that needs reconciling.

## 1. Confirm the shared memory root

Default location: `~/.claude-shared-memory`. If `install.sh` was already
run, it exists. If not, create it now (`mkdir -p`) and tell the user what
location you used, in case they'd prefer a different one — ask before
moving it if they push back, don't just proceed silently once a location
is already in use.

## 2. Register the session hooks

Confirm `jq` is on `PATH` first (`command -v jq`). If it's missing, tell
the user to run `mise install` in this repo (it's pinned in `mise.toml`)
before continuing — don't register hooks that will fail at runtime.

Determine this repo's absolute path (`git rev-parse --show-toplevel` if
run from inside it; call it `<repo>` below) — hook commands in
`settings.json` need an absolute path, since this repo could be cloned
anywhere.

Use the `update-config` skill to add these hooks to `~/.claude/settings.json`
— don't hand-edit the file directly; `update-config` knows the current hook
schema and merges safely instead of clobbering existing hooks.

- `SessionStart` → `<repo>/adapters/claude-code/hooks/session-start.sh`
- `Stop` → `<repo>/adapters/claude-code/hooks/stop.sh`

Both read the hook's JSON from stdin and take no arguments — the command
is just the bare script path. If step 1 used a non-default shared root
(anything other than `~/.claude-shared-memory`), that location needs to
reach the hooks too: prefix each command with
`SHARED_AGENT_MEMORY_ROOT=<chosen path>` (e.g.
`SHARED_AGENT_MEMORY_ROOT=/custom/path <repo>/adapters/claude-code/hooks/session-start.sh`)
rather than assuming the wrapper's built-in default.

## 3. Offer migration

Check whether this host has pre-existing per-project-launch-directory
memory stores (look under `~/.claude/projects/`) that predate this tool.
If any exist, tell the user what was found and ask whether to run the
`shared-agent-memory-migrate` skill now or later. Don't run it unprompted — migration involves
human-reviewed judgment calls on conflicting facts, per that skill's own
instructions.
