---
name: shared-agent-memory-setup
description: One-time setup for shared-agent-memory on this host — makes sure install.sh has run and is current, registers the Claude Code hooks, and hands off to migration for any pre-existing memory stores.
---

# shared-agent-memory: setup

Run this once per host, the first time `shared-agent-memory` is installed there. Safe to re-run — every step below should no-op if it's already done.

## 0. If this isn't the first host, pair Syncthing first

Ask the user whether another host is already running `shared-agent-memory` with real content in its shared root. If so, and Syncthing isn't already paired and syncing between this host and that one, stop here and point them at `README.md`'s "Getting started" section (the "Each additional host" part) to install and pair Syncthing first — don't continue to step 1 yet. Confirm the shared root here already shows synced content (folder "Up to Date" in Syncthing's GUI, real files already present) before moving on. If this genuinely is the first host, skip straight to step 1.

**Why this order matters:** step 3's migration compares this host's own pre-existing memory against whatever's already at each shared-root key. If nothing's synced in yet, migration only has this host's own content to work with, and a real cross-host merge (e.g. two independently-built `_personal` stores) can't happen properly — it gets treated as fresh content instead of something that needs reconciling.

## 1. Make sure `install.sh` has run, and is current

`install.sh` creates the shared memory root, links this repo's skills into `~/.claude/skills/`, links `~/.claude/rules` to the shared root's `_rules/` bucket, and records the repo's install version for this host. Creating only the shared root folder by hand leaves the rest missing, and the `SessionStart` hook would report the host as out of date on its very first session.

Determine this repo's absolute path (`git rev-parse --show-toplevel` if run from inside it; call it `<repo>` below), then compare the version the repo expects with the one this host recorded:

```
cat <repo>/install-version
cat ~/.local/state/shared-agent-memory/installed-version
```

- **Recorded version missing, or lower than the repo's:** run `<repo>/install.sh`. Default shared root is `~/.claude-shared-memory`; if the user wants a different location, pass `--root <path>` and use that same path in step 2. Tell the user which location was used, in case they'd prefer a different one — ask before moving it if they push back, don't just proceed silently once a location is already in use.
- **`install.sh` warned that it skipped something** (a skill, or `~/.claude/rules`, blocked by something already there): show the user exactly what was skipped and why, and stop here until it's resolved and `install.sh` re-runs cleanly. Don't register hooks on a partially installed host.
- **Recorded version equal to or higher than the repo's:** already installed; confirm the shared root exists and move on.

## 2. Register the session hooks

Confirm `jq` is on `PATH` first (`command -v jq`). If it's missing, tell the user to run `mise install` in this repo (it's pinned in `mise.toml`) before continuing — don't register hooks that will fail at runtime.

Use the absolute `<repo>` path from step 1 — hook commands in `settings.json` need an absolute path, since this repo could be cloned anywhere.

Use the `update-config` skill to add these hooks to `~/.claude/settings.json` — don't hand-edit the file directly; `update-config` knows the current hook schema and merges safely instead of clobbering existing hooks.

- `SessionStart` → `<repo>/adapters/claude-code/hooks/session-start.sh`
- `Stop` → `<repo>/adapters/claude-code/hooks/stop.sh`

Both read the hook's JSON from stdin and take no arguments — the command is just the bare script path. If step 1 used a non-default shared root (anything other than `~/.claude-shared-memory`), that location needs to reach the hooks too: prefix each command with `SHARED_AGENT_MEMORY_ROOT=<chosen path>` (e.g. `SHARED_AGENT_MEMORY_ROOT=/custom/path <repo>/adapters/claude-code/hooks/session-start.sh`) rather than assuming the wrapper's built-in default.

## 3. Offer migration

Check whether this host has pre-existing per-project-launch-directory memory stores (look under `~/.claude/projects/`) that predate this tool. If any exist, tell the user what was found and ask whether to run the `shared-agent-memory-migrate` skill now or later. Don't run it unprompted — migration involves human-reviewed judgment calls on conflicting facts, per that skill's own instructions.
