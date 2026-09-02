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
- If the original directory no longer exists at all, skip it — nothing to
  migrate, nothing to clean up.
- If it still exists but the `memory/` subdirectory itself has no memory
  files in it (whether or not session transcripts sit alongside it in the
  parent `~/.claude/projects/<slug>/` directory — those are untouched
  either way, not this tool's concern), remove the empty `memory/`
  directory rather than leaving it in place. An empty non-symlink
  directory still blocks `link-memory.sh` from creating a fresh symlink
  on every future session launched from there — and since there's no
  content at risk inside `memory/`, the backup-first caution in step 4
  doesn't apply here.

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

**If `<shared-root>/<key>/` already has content, treat that as part of the
group too** — even when there's only one local store on this host. This
happens whenever Syncthing has already synced another host's content into
this key before migration runs here (the expected order: pair Syncthing
with an existing host *before* running this skill on a new one, so this
is the common case, not an edge case). A single local store migrating
into an already-populated key needs the same-key merge process below —
**but if that local store is the mixed home-directory store, run the
per-file classification from step 3 first.** Classification and same-key
merging are two separate passes that both apply to the home-directory
case, not alternatives — don't let "there's already content at `_personal`"
skip straight to comparing the whole store against it. Classify every
file first (personal / this project's own key / this host specifically /
unresolved); only the files that come out classified as genuinely
`_personal` are what then go through the same-key duplicate-fact merge
against what's already there. A file that turns out to be host- or
project-specific never enters that merge at all — it goes straight to its
own destination, whether or not anything's already sitting at `_personal`.

## 3. Migrate each group

**Single store, no collision, homogeneous content:** move its memory
files into `<shared-root>/<key>/`.

**Single store, mixed content (typically the `_personal`/home-directory
store):** don't move the whole store as one unit — classify file by file
instead. For each memory file, read it and decide:

- Is it a `feedback`-type memory (per its frontmatter `metadata.type`)
  with no specific project tied to it, and nothing about it is specific
  to *this host* either? → `_personal`, untagged.
- Does it document something true of this host specifically — hardware,
  local network, anything that would be wrong information if read on a
  different machine — regardless of memory `type`? → still `_personal`
  (it's not project-specific, and there's no separate host-scoped
  bucket), but add `hosts: [<hostname>]` to its frontmatter before moving
  it. This is the same `hosts:` field used for host-scoped
  feedback/behavior memory, generalized to any memory type — a memory
  file being scoped to one host isn't a `feedback`-only concept. Don't
  invent a `_personal-<host>`/`_host-<host>` bucket for this; a second
  bucket only answers "which folder" and still leaves "does anything
  respect the scope" unsolved, which the `hosts:` field already answers
  on its own.
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

This classification pass always runs first, whether or not `_personal`
already has content from another host. If it does (see step 2), the
files classified as `_personal` here are what feed into the same-key
merge below — classify the whole store before checking any of it against
what's already there, don't merge first and classify whatever's left.

**Multiple stores, same key:** this is a real merge, not a move. Read every
store in the group, and for each memory file / `MEMORY.md` entry:

- If it exists in only one store, keep it.
- If the same fact appears in multiple stores, keep one copy.
- If one version is a strict superset of the other (a diff shows only
  pure additions past a shared prefix — nothing removed, nothing
  reworded), that's not a conflict, just staleness: keep the superset
  automatically, no need to ask. This is the common shape for the same
  feedback memory continuing to accumulate instances on one host after a
  shared seed — the older copy isn't wrong, just behind.
- If stores genuinely disagree, or cover different non-overlapping ground
  about the same topic, show the user both versions and ask how to
  reconcile them — do not silently pick one or concatenate them without
  review.

**Finding duplicate facts across stores is two different checks, not one**
— independently-authored stores (e.g. the same person's `_personal`
feedback, separately built up on two different hosts) won't reliably
share filenames, so a filename match alone misses real duplicates:

1. **Same filename in both stores:** cheap case. Diff the two directly.
   Identical is a duplicate — keep one. If the diff is pure appends past
   a shared prefix (one strictly contains the other), that's a superset,
   not a conflict — keep the newer/fuller one automatically. Only a diff
   with actual removals or rewrites past that shared prefix is a genuine
   conflict — ask.
2. **Different filenames, possibly the same fact:** the more likely case
   across hosts. No filename to lean on, so compare content instead —
   first pull `name:`/`description:` frontmatter across both stores (cheap
   to scan for likely matches across many files), then read the full body
   of any suspected pair before deciding. Same rule as above once a real
   match is confirmed: identical fact, keep one; genuinely different or
   complementary, keep both.

Don't skip straight to a full-body diff of everything — with two stores
of a dozen-plus files each, that's a lot of reading for what the
frontmatter scan usually resolves in one pass.

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

Flag separately: any migrated file that documents shared-agent-memory's own
setup/install state on this host (e.g. "hooks installed but paused pending
X") — that kind of memory self-invalidates the moment migration actually
runs, so call it out as likely needing retirement rather than silently
carrying it forward as if it were still durable fact.
