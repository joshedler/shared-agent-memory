---
name: shared-agent-memory-uninstall
description: Reverse shared-agent-memory on this host — stop the hooks, restore real content in place of the symlinks they created, and leave shared/backup data for the user to remove manually.
---

# shared-agent-memory: uninstall

Reverses shared-agent-memory on **this host only**. Cross-host reversal
isn't attempted — a shared folder that's synced across multiple hosts has
no per-fact record of which host contributed what, so "give this host
back exactly what it originally contributed" isn't reconstructable once
content has merged. What *is* well-defined, and what this does: give this
host's native memory directories back real content, and stop this host
from creating any more links or locks. Uninstalling host by host is fine
— nothing here needs every host to act at once.

## 1. Stop new activity

Use the `update-config` skill to remove the `SessionStart` and `Stop`
hook entries whose command references
`adapters/claude-code/hooks/session-start.sh` or `stop.sh` from
`~/.claude/settings.json` — identify them by that path, not just by event
name, since other unrelated hooks (e.g. pre-existing `SessionStart`
hooks) may already be registered and must stay untouched. Do this first,
before anything else, so nothing new gets linked while the rest of this
runs.

If Syncthing (or any other sync tool) is set up for the shared root, tell
the user to pause syncing or unshare the folder on this host now, before
continuing. This matters for two reasons: it stops the shared content
from changing out from under you while step 3 reads it, and — more
importantly — it prevents a local deletion later (step 5, on the shared
root) from propagating as a deletion to *other* hosts that aren't being
uninstalled, depending on how delete-propagation is configured. Don't
proceed past this step until the user confirms sync is paused, if they
have it set up at all.

## 2. Inventory what's linked

Scan `~/.claude/projects/*/memory` for symlinks that resolve into the
shared root (`$SHARED_AGENT_MEMORY_ROOT`, default
`~/.claude-shared-memory`). For each one found, note the native path and
which shared-root subfolder it points to. This inventory is fully
reconstructable from the symlinks themselves — nothing else needs to be
consulted, no separate record was ever kept.

Present the full list to the user before touching anything. Don't start
restoring content per-item without them seeing the whole scope first.

## 3. For each linked project, restore real content

For each entry from step 2:

- Check whether a migration backup exists for that native slug
  (`~/.local/state/shared-agent-memory/backups/<slug>-*/`). If one does,
  ask the user which they want: the **current** shared content (which may
  include contributions merged in from other hosts, if this project was
  ever synced), or the **original pre-migration snapshot** from the
  backup. If no backup exists, there's only one option — the current
  shared content — since nothing else was ever native to this host.
- Remove the symlink at the native path.
- Create a real directory there and copy the chosen content into it.
- Report what happened for that project before moving to the next.

## 4. Clean up session state

Remove `~/.local/state/shared-agent-memory/sessions/*` — pure ephemeral
bookkeeping (session_id → project key), safe to delete unconditionally;
nothing real is ever stored there.

## 5. Leave the rest for the user

Do **not** delete these — they're either real data or an explicit safety
net, and removing them is the user's call, not this skill's:

- The shared root itself (`$SHARED_AGENT_MEMORY_ROOT`) — only remove once
  every project the user cares about has gotten real content restored in
  step 3, **and** only after confirming this host is actually unshared
  from sync (step 1) — deleting it while still shared risks deleting it
  on other hosts too.
- Migration backups (`~/.local/state/shared-agent-memory/backups/`) —
  same policy as always: kept until the user is satisfied, removed
  manually, never by a script.

Tell the user these still exist and where, rather than silently leaving
them unmentioned or silently removing them.

## 6. Remove the globally-installed skills

Remove every `~/.claude/skills/shared-agent-memory-*` entry that's a
symlink into this repo (`install.sh` links every `.claude/skills/*/`
subdirectory it finds, so the exact set can grow — don't hardcode a name
list here) — safe, they're just symlinks into the repo, not real data.

## 7. Tell the user what's left

The repo itself (wherever it was cloned) isn't touched by this skill —
mention that removing it is the final manual step, whenever they're
ready.
