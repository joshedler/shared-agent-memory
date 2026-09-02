---
name: shared-agent-memory-migrate
description: Port a host's existing per-project-launch-directory Claude Code memory stores into the shared-agent-memory root, merging any that collide on the same resolved project key.
---

# shared-agent-memory: migrate

Run this on a host that has memory stores under `~/.claude/projects/`
predating shared-agent-memory. It's interactive by design — conflicting
facts between stores need a human's judgment, not a silent merge.

## 1. Inventory existing stores

For each `~/.claude/projects/<slug>/memory/` that has content:

- Recover the directory the session was originally launched from. The slug
  encodes the path (e.g. a slug like `-home-<user>-dev-<project>` decodes
  to `/home/<user>/dev/<project>`).
- If that directory still exists and has a git remote, resolve the
  project key from it (canonicalized remote URL).
- If it has no remote, check for a marker file (`.claude-project-id`); if
  neither exists, this store's content is a candidate for the
  `_unresolved/` bucket rather than a project key — flag it and ask the
  user rather than guessing.
- If the original directory no longer exists at all, or the store has no
  memory files (just session transcripts), skip it — nothing to migrate.

The store launched from the home directory itself resolves to the
reserved `_personal` key (see `core/resolve-key.sh`), not `_unresolved` —
but don't assume all of its content actually belongs there. Nothing stops
a project-relevant fact from being learned (and written down) while
poking around from home rather than from inside that project's own
checkout, so this store is the one most likely to need the per-file split
described in step 3, not a whole-store move.

## 2. Group by resolved key

Multiple old stores can resolve to the same key — this is the motivating
case (cwd-based launch scoping fragmenting one project's memory across
multiple slugs). Group them before touching anything.

## 3. Migrate each group

**Single store, no collision, homogeneous content:** move its memory
files into `<shared-root>/<key>/`.

**Single store, mixed content (typically the `_personal`/home-directory
store):** don't move the whole store as one unit — classify file by file
instead. For each memory file, read it and decide:

- Is it a `feedback`-type memory (per its frontmatter `metadata.type`)
  with no specific project tied to it? → `_personal`.
- Does it document a fact, decision, or behavior specific to one
  resolvable project (a `project`-type memory, or a `feedback` memory
  whose content only makes sense in that project's context, even if it
  happened to get written while launched from home)? → that project's own
  key — read what's already there first, since this becomes a same-key
  merge (see below) rather than a plain move whenever that project has
  its own pre-existing store too.
- Genuinely unclear, or about a project with no resolvable key yet? →
  `_unresolved/<original-slug>/`, same as a whole unresolved store.

Show the resulting per-file classification to the user before moving
anything — this is exactly the kind of judgment call this skill exists to
surface, not silently resolve. Splitting a store this way still ends with
exactly one destination for the store's own memory *path* itself (see
step 4) — for the home-directory case, that's `_personal`, since
whatever's left there after pulling out the project-specific files is
what actually stays home-agnostic.

**Multiple stores, same key:** this is a real merge, not a move. Read every
store in the group, and for each memory file / `MEMORY.md` entry:

- If it exists in only one store, keep it.
- If the same fact appears in multiple stores, keep one copy.
- If stores genuinely disagree, or cover different non-overlapping ground
  about the same topic, show the user both versions and ask how to
  reconcile them — do not silently pick one or concatenate them without
  review.

**Unresolved (no key, no marker, declined):** move into
`<shared-root>/_unresolved/<original-slug>/` rather than discarding it.

## 4. Back up, then replace with a symlink

Before touching the original `~/.claude/projects/<slug>/memory/` directory,
copy it in full to
`~/.local/state/shared-agent-memory/backups/<slug>-<timestamp>/`. Only
after that backup exists, replace the original directory with a symlink to
`<shared-root>/<key>/` (or `_unresolved/<slug>/`).

Never delete the backup as part of this skill — that's the user's call,
later, once they've confirmed the migration captured everything correctly.

## 5. Report back

Summarize what moved where, what got merged (and what judgment calls were
made), and what's sitting in `_unresolved/` awaiting a real key.
