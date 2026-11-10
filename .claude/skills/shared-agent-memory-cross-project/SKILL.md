---
name: shared-agent-memory-cross-project
description: Handle a memory-worthy fact that concerns a different project than the one this session's own launch directory resolved to — either by writing it directly into that project's real shared bucket, or by suggesting the user relocate there, depending on how much of the current work is actually about it.
---

# shared-agent-memory: cross-project memory

Claude Code's native auto-memory always writes through this session's own resolved project path — fine when the session's launch directory matches what's being discussed, wrong whenever it doesn't (working on Project A from `$HOME`, from Project B's checkout, from a scratch directory). Nothing at the hook layer can catch this: `session-start.sh` only ever sees `cwd`/`session_id`, once, at session start. Catching it is on you, in the moment, right before a fact would otherwise land in the wrong bucket.

**Trigger:** you're about to write (or would normally let native auto-memory write) something that's actually about a project other than the one this session resolved to — a fact, decision, or piece of feedback whose content only makes sense in that other project's context.

## 1. Judge how much of the current work is actually about that project

This is the fork the mechanism below exists to serve — don't skip straight to step 2 just because the trigger fired.

- **Sustained** — the current conversation's substantive work (code, design, most of the recent turns) is actually about the other project, not a tangent from it. Don't use the write mechanism below. Instead, tell the user directly: this session is doing real work on `<other project>` from outside its own checkout, and memory would be more reliably tracked by resuming or continuing this work from inside `<other project>`'s own directory. Relocating isn't just cheaper than a redirected write — it's more correct: it lets the project's own advisory lock follow its normal acquire/release lifecycle (via `SessionStart`/`Stop`) instead of being worked around, and every future memory write in that session lands in the right place by default, not by you noticing each time. Frame it as a suggestion, not a requirement — the user may have a reason to stay put.
- **Incidental** — a one-off fact or aside that doesn't warrant a context switch (an offhand "that reminds me, project X also does Y" during otherwise-on-topic work). Continue to step 2.

## 2. Resolve the target project's real key

You need a concrete local filesystem path to the other project's checkout on this host. If you don't already have one from the conversation (you've read files there, the user named a path), ask rather than guessing.

Run `core/resolve-key.sh <path>` (absolute path to that repo, from this repo's root). If it exits 1 (no git remote, no `.claude-project-id` marker), stop and tell the user — this skill doesn't attempt the `_unresolved/` fallback the hooks use; a redirect needs a real, stable key or writing there would just relocate the mis-routing problem instead of fixing it.

## 3. Take a short-lived lock, write, release it

The write itself needs the same protection a normal session's memory writes already get — this session isn't otherwise a participant in the target project's lifecycle, so it has to take and drop its own lock around just this operation rather than relying on any lock a `SessionStart` hook already holds.

```
shared_root="${SHARED_AGENT_MEMORY_ROOT:-$HOME/.claude-shared-memory}"
core/lock.sh acquire "${shared_root}" "<key>" "<this session's session_id>" --ttl 60
```

- If the result is `clean`, proceed.
- If `conflict` (another host has this project open right now): this is a real concurrent-write risk, not just informational the way `SessionStart`'s conflict notice is — tell the user and confirm before writing rather than proceeding silently.
- If `stale-reclaimed`, proceed; note it to the user in passing.

Write the fact into `${shared_root}/<key>/` using the same memory-file format (frontmatter, `name`/`description`/`metadata.type`) and `MEMORY.md` indexing convention your native auto-memory already follows — same schema, just a different, explicit target path instead of the session's own symlinked one. Create `${shared_root}/<key>/` and its `MEMORY.md` if this is the target project's first memory.

Then release, unconditionally, even if the write failed partway:

```
core/lock.sh release "${shared_root}" "<key>" "<this session's session_id>"
```

## 4. Tell the user what happened

State plainly what was written and where (`<key>`, not this session's own project) — a write to a path other than the session's own native memory location is exactly the kind of thing that should stay visible, not happen silently.
