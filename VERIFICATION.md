# Manual verification

`core/` and `install.sh` have a deterministic `bats` suite (`mise run test`). Everything below can't be covered that way — it needs a real Claude Code session, a real second host, or a real pre-existing memory store to exercise honestly. This is the checklist for that: one scenario per flow this tool claims to handle, with the setup, the action, and the expected result, so a run can be checked off rather than re-derived from memory (yours or the agent's) each time.

Host- and user-agnostic by design — every scenario below uses placeholders (`<host-a>`, `<host-b>`, `~/dev/<project>`) rather than real machine names or paths, so this file stays safe to read and run on any host, and so a completed checklist doesn't leak details about who ran it or where.

Each item's status reflects whether it's been run at least once against real state, not whether the underlying code has test coverage:

- ✅ verified — run at least once against real state, outcome matched
- ◻ not yet run

Run these on a throwaway project/directory, not one you'd mind losing — several scenarios intentionally exercise lock contention, stale state, and first-run prompts.

## Setup and migration

- ✅ verified — **Fresh host, no prior state.** On a host with no `~/.claude-shared-memory` and no shared-agent-memory hooks registered: run the `shared-agent-memory-setup` skill. Expect: shared root created (default `~/.claude-shared-memory` unless told otherwise), `SessionStart`/`Stop` hooks present in `~/.claude/settings.json`, and — only if pre-existing per-launch-directory memory stores are found under `~/.claude/projects/` — an offer (not an automatic run) of the `shared-agent-memory-migrate` skill. This is this tool's own first-host bootstrap, not a separate trial run.
- ✅ verified — **Second host, paired via Syncthing first.** Pair Syncthing between `<host-a>` (already running shared-agent-memory with real content) and `<host-b>` (new) _before_ running setup on `<host-b>`. Confirm the shared-root folder shows "Up to Date" with real files on `<host-b>` before running `shared-agent-memory-setup` there. Expect: migration on `<host-b>` treats `<host-a>`'s already-synced content as part of the merge, not as untouched fresh content.
- ◻ **Migration: single homogeneous store.** A pre-existing `~/.claude/projects/<slug>/memory/` whose original launch directory still exists and resolves to a real key, with no unrelated content mixed in. Expect: moved as a whole into `<shared-root>/<key>/`, original path backed up under `~/.local/state/shared-agent-memory/backups/`, then replaced with a symlink.
- ✅ verified — **Migration: mixed home-directory store.** A pre-existing `_personal` (home-launched) store containing at least one project-specific fact, one host-specific fact, and one genuinely general fact. Expect: per-file classification shown before anything moves; project-specific file lands at that project's own key; host-specific file lands in `_personal` with `hosts: [<host>]` added to its frontmatter; general file stays in `_personal` untagged.
- ✅ verified — **Migration: same-key merge across stores.** Two pre-existing stores (same host or two hosts synced together) that resolve to the same project key, with at least one duplicate fact (same content, different filename) and one genuine conflict. Expect: the duplicate is caught via content comparison (not just filename matching) and kept once; the conflict is shown to you for a decision, never silently resolved.
- ◻ **Migration: unresolved store.** A pre-existing store whose original launch directory has neither a git remote nor a `.claude-project-id` marker. Expect: moved to `<shared-root>/_unresolved/<original-slug>/`, not discarded and not guessed into a project key.
- ◻ **Uninstall.** Run `shared-agent-memory-uninstall` on a host with real synced content. Expect: hooks removed from `~/.claude/settings.json`, each native memory symlink replaced with a real copy of its current content (not left as a dangling or orphaned symlink), the `~/.claude/rules` link either replaced with a real copy of `_rules/` or removed (your choice), and shared-root / backup data left alone for manual removal.
- ✅ verified — **Shared rules load in every session.** With `~/.claude/rules` linked to `<shared-root>/_rules` by `install.sh`, start sessions from a resolved project, from `$HOME`, and from an unresolved directory. Expect: `/memory` (or `/status`) lists the `_rules/` files as loaded in each, and the session can quote them without reading any file.
- ✅ verified — **Existing host told to re-run `install.sh`.** On a host installed before `install-version` existed (or with its recorded version behind the repo's), pull and start a session without re-running `install.sh`. Expect: the session's first context mentions re-running `install.sh`, and you see a `systemMessage` saying the same. After a clean `./install.sh`, the next session is silent about it.

## Session lifecycle

- ✅ verified — **Normal project session.** Launch a session inside a real project with a git remote. Expect: native memory path becomes a symlink to `<shared-root>/<key>/`, matching the canonicalized remote URL (ssh/https forms of the same remote resolve to the same key).
- ✅ verified — **Lock acquired and released cleanly.** Launch a session in a project, do some work, let the session end normally (`Stop` fires). Expect: lock acquired at `SessionStart` (status `clean`), released at `Stop`, no leftover state file under `~/.local/state/shared-agent-memory/sessions/`.
- ◻ **Lock conflict.** With a session already open on `<host-a>` for a project, start a second session on `<host-b>` for the same project key (real second host, or simulated via a second `SessionStart` invocation with a different session id while the first hasn't released). Expect: the second session's `SessionStart` reports a `conflict` `additionalContext` naming the other host and time — informational, not blocking.
- ◻ **Stale lock reclaimed.** Leave a lock held past its TTL by a session that never got a `Stop` (kill the process rather than exiting cleanly). Expect: the next `SessionStart` for that project reports `stale-reclaimed` and proceeds normally rather than treating it as a live conflict.
- ✅ verified — **Unresolved-directory prompt flow.** Launch a session from a directory with no git remote and no `.claude-project-id` marker. Expect: memory links under a synthetic `_unresolved/<native-slug>` key (no lock), and the _first_ such session emits a one-time `additionalContext` suggesting a real marker file. A second session from the same directory should not repeat the prompt (check the sentinel under `~/.local/state/shared-agent-memory/unresolved/`).
- ◻ **`_personal` bucket, concurrent sessions.** Launch two sessions from `$HOME` itself at the same time. Expect: both resolve to `_personal`, neither reports a lock conflict — concurrent home-launched sessions are normal, not a handoff.

## Cross-project memory (`shared-agent-memory-cross-project` skill)

- ◻ **Incidental redirect, clean lock.** From a session resolved to project A, surface a one-off fact that's actually about project B (a separate real checkout on the same host, not currently open elsewhere). Expect: the skill resolves project B's key via `resolve-key.sh`, takes a short-lived lock (`clean` status), writes the fact into `<shared-root>/<project-B-key>/` (not project A's bucket), releases the lock, and tells you what was written and where.
- ◻ **Incidental redirect, lock conflict.** Same as above, but with a real session already open on project B on another host at the time of the write. Expect: the skill surfaces this as a real concurrent-write risk and asks for confirmation before writing — does not write silently the way `SessionStart`'s own conflict notice does.
- ◻ **Sustained work, suggest relocation.** Start a session outside any project's checkout (e.g. `$HOME`) and do substantial real work (several turns of code/design, not an aside) that's actually about a specific other project on the same host. Expect: the agent proactively suggests resuming from inside that project's own checkout, and does not silently redirect memory writes there instead.
- ◻ **Unresolvable redirect target.** Attempt an incidental redirect where the target path has neither a git remote nor a `.claude-project-id` marker. Expect: the skill stops and tells you rather than falling back to `_unresolved/` or guessing a key.

## Adding a new scenario

A new flow (a new skill, a new fallback path, a new failure mode in an existing one) gets a checklist item here in the same pass that builds it, not as a follow-up — this file's value is being a complete map of what's been accounted for, not just what's convenient to remember.
