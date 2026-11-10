# shared-agent-memory

Give a coding agent's persistent memory the ability to follow you across machines, instead of being pinned to wherever a session happened to start.

## The problem

Many coding agents keep a persistent memory store as plain files on disk, scoped per project or per launch directory. Two things go wrong with that:

1. **Same-host fragmentation.** If a tool scopes memory by the directory a session was _launched_ from rather than the project actually being worked on, the same project silently accumulates multiple, non-overlapping memory stores depending on where you happened to start the session.
2. **No cross-host continuity.** Memory lives on one machine. Picking up the same project from a different machine starts from zero context, even though another host may hold real, relevant history about that exact project.

## Approach

This is a file-sync problem, not an AI-memory-product problem — the agent already turns conversation into structured memory files as part of normal operation, so there's no need for a separate extraction/embedding pipeline (and no need to send conversation content to any third-party service to get cross-host recall working).

- **Project key resolution.** Each project resolves to one canonical key, computed the same way on every host: primarily the project's git remote URL (canonicalized so ssh and https forms match), falling back to an explicit marker file for projects with no remote. A session launched from the home directory itself (not inside any project) resolves to a reserved `_personal` key instead — the always-synced, host-agnostic home for feedback/behavior memories that aren't tied to a specific project. Unlike project keys, `_personal` carries no advisory lock: concurrent sessions from the home directory are normal, not a handoff to warn about. Any other directory that resolves to neither a remote nor a marker still gets linked — under a synthetic `_unresolved/<native-slug>` key, no lock (there's no real cross-host identity to arbitrate for it) — kept apart from `_personal` so a project someone just hasn't set up a marker for yet doesn't get mixed in with content that's genuinely host-agnostic. The first session to hit a given directory this way gets a one-time `additionalContext` prompt suggesting a real `.claude-project-id` marker instead; a sentinel file records that the prompt already happened so it's only ever asked once per directory, whether the answer was to create the marker or to leave it as-is.
- **Standing rules for every session.** A reserved `_rules/` bucket at the shared root holds working rules meant to apply on every host and in every project, not just one project's sessions or home-launched ones. `install.sh` symlinks Claude Code's user-level rules directory, `~/.claude/rules`, to it, so Claude Code's own rules loading picks the files up in every session — no hook involved, same "symlink, not copy" approach as memory. Claude Code reads that directory recursively, so anything in `_rules/` (subdirectories included) is loaded; keep archived or draft rules outside it.
- **Shared root, synced continuously.** One directory tree, one subfolder per resolved project key, kept in sync across hosts by [Syncthing](https://syncthing.net/) (P2P, encrypted, no server to run, syncs in the background so hosts don't need to be online at the same time).
- **Nested project directories, not flattened.** A resolved key that contains real path separators (e.g. a git host's `host/owner/repo`) becomes real nested directories under the shared root, not a single flattened folder name. A git host's own naming rules already guarantee filesystem-safe characters in each segment, so there's no need for an escaping or flattening scheme — and flattening (e.g. collapsing `/` to `-`) would introduce exactly the kind of collision risk this project otherwise avoids: two different projects silently mapping to the same folder. Nesting also means every local checkout of the same remote (a second clone, a worktree, a differently-named directory) resolves to the same key and therefore the same shared folder, and it mirrors an established convention (e.g. Go's `$GOPATH/src/<host>/<owner>/<repo>` workspace layout) rather than inventing a new one.
- **Symlink, not copy.** On a host, the agent's own per-project memory path is replaced with a symlink into the shared root's matching subfolder. Nothing about how the agent reads or writes memory files changes — the only new logic is resolving the key and managing the symlink.
- **Advisory lock, not distributed consensus.** Because the shared root is only eventually consistent, a hard cross-host lock isn't achievable and isn't the goal — the real goal is sequential handoff between hosts (work on host A, then pick up on host B), not simultaneous editing from two hosts at once. A lock file in each project's subfolder records which host last opened a session there and when, so a new session on another host can warn ("active session on `<host>` as of `<time>`") rather than either blocking outright or silently forking context. A configurable TTL (default 4 hours) keeps a crashed or sleeping host from leaving a permanent phantom lock; reclaiming a stale lock is surfaced to the user, not silent, using the same relay mechanism as a live conflict.
- **Layered behavior memory.** Feedback/behavior-type memories (how you expect the agent to work — not project facts) can carry an optional `hosts:` scope, defaulting to "applies everywhere" when unset. The most specific match wins: a memory scoped to one host _and_ one project beats one scoped to just the project, which beats an unscoped global default. Everything stays in the synced store regardless of scope, so every host can see the full picture — including exceptions that don't apply to it — rather than exceptions being silently invisible on other hosts. **This is a simplicity/commonality trade-off, not a proven mechanism** — worth revisiting if it doesn't hold up once there's real layered behavior memory to test it against.
- **Status/observability tooling.** A plain script (agent-agnostic, usable outside Claude Code, cron-able) reports per-project subfolder size and last-modified time, total shared-root size, per-host lock state, and Syncthing's own sync/conflict status where queryable. A thin Claude Code skill wraps it so it can be asked for conversationally rather than by remembering command syntax.

## Migration

Existing per-project-launch-directory memory stores need one-time porting into the shared root before this is usable. Where multiple old stores resolve to the same project key, they're merged with a human reviewing any conflicting facts, not auto-collapsed. Whatever a migrated-from directory held is moved to a dedicated out-of-band backup location (outside `~/.claude/projects/`, the shared root, and this repo) rather than left alongside the new symlink or deleted.

A memory store launched from the home directory is a special case: it's rarely _all_ `_personal` content, since nothing stops project-relevant facts from ending up there too (e.g. a fact learned about a project while poking around from home rather than inside its checkout). The migration skill covers this — splitting such a store file-by-file, with project-specific facts going to their own resolved keys and the rest to `_personal` — and it's been run for real, not just designed: a host's actual mixed home-directory store, with a couple dozen files split across four different project keys plus `_personal`, migrated cleanly.

## Non-goals

- **Reconciling memory across different agent products.** This project assumes every host in the mesh is running the same agent tool (today: Claude Code, via `adapters/claude-code/`). Mixing different coding agents and expecting them to share one memory pool isn't handled and shouldn't be assumed to work.
- **Enforcing a specific network topology for Syncthing.** No particular setup (LAN, Tailscale/Headscale, public relays) is required or assumed. Syncthing has defaults (global discovery, relay servers) that are riskier than a fully private mesh — anything that touches setup here should point that out and note a private mesh (e.g. Tailscale/Headscale) as one safe option, but the actual exposure choice is the user's to make.

## Getting started

**First host:**

1. `./install.sh` — creates the shared memory root (default `~/.claude-shared-memory`), symlinks `.claude/skills/*` into `~/.claude/skills/` so they're available from any session on this host, links `~/.claude/rules` to the shared root's `_rules/`, and records this repo's install version for the host.
2. In Claude Code, run the `shared-agent-memory-setup` skill to register this host's hooks — it runs `install.sh` itself first if step 1 was skipped or is out of date, and hands off to `shared-agent-memory-migrate` automatically if this host has pre-existing per-project memory stores to port in.

**Each additional host — pair Syncthing with an existing host _before_ running setup here, not after:**

`shared-agent-memory-setup`'s migration step compares this new host's own pre-existing memory against whatever's already at each shared-root key. If Syncthing hasn't synced anything in yet, migration only has this host's own content to look at — a real cross-host merge (e.g. two independently-built `_personal` stores, one per host) can't be evaluated properly, and content that should have been reconciled against what another host already has just gets treated as new.

1. Install Syncthing on both hosts — see [syncthing.net/downloads](https://syncthing.net/downloads/) for your platform's package. Run it as a background service (Syncthing's own docs cover autostart for your OS/init system); on Linux with systemd that's typically a `syncthing` user service (start on login) or a `syncthing@<username>` system service (start at boot regardless of login) — pick based on whether the host is normally logged-in-and-running.
2. Open the web GUI (`http://localhost:8384` by default) on each host, **Actions → Show ID**, to get each host's Device ID.
3. **Set a GUI password on each host** — **Actions → Settings → GUI**, fill in a username and password under Authentication, save. Syncthing's web GUI and REST API have no authentication by default, and anything that can reach `localhost:8384` can read/write your synced memory through it — worth doing before pairing, not after.
4. On each host, **Add Remote Device** with the _other_ host's Device ID — this is mutual, both sides need to add each other. Accept the "device wants to connect" prompt that appears on the other side after a short delay.
5. On one host, add/edit the shared memory root folder (default `~/.claude-shared-memory`, or wherever `--root` pointed it during `install.sh`), open its **Sharing** tab, check the other device, save. Accept the incoming folder-share prompt on the other host, confirming its own local path.
6. Confirm both sides show the folder "Up to Date" with matching item counts before continuing.
7. Only now run `./install.sh` and the `shared-agent-memory-setup` skill on the new host — migration will see the already-synced content and can merge against it properly.

If the two hosts aren't on the same LAN, you may need `22000/TCP` + `22000/UDP` open for sync traffic and `21027/UDP` for local discovery; same-LAN pairing usually needs nothing opened. See the Non-goals section above for the exposure tradeoff in Syncthing's own defaults.

`AGENTS.md` is the same guidance aimed at an agent that's just been pointed at this repo cold.

## Updating

`git pull` alone doesn't reach a host's global setup — `install.sh`'s symlinking only ran once, at install time. A new skill added to `.claude/skills/` after that, or a new link `install.sh` manages, needs `./install.sh` re-run on each host to pick it up.

You don't have to remember which pulls need that. The repo's `install-version` file holds a number, bumped by any change that needs a re-run; a clean `install.sh` run records it for the host under `~/.local/state/shared-agent-memory/`. Because the `SessionStart` hook runs straight from the repo checkout, it sees a pull immediately, and when the host's recorded number is missing or behind, every session says so (to you and to the agent) until `./install.sh` is re-run. A run that skips anything (a skill or link blocked by something already in the way) doesn't record the number, so the reminder stays until it's resolved. Re-running `install.sh` is idempotent, so doing it after every pull is always safe too.

## Testing

Scripts under `core/` and `install.sh` have a `bats` (Bash Automated Testing System) suite in `test/`. `mise.toml` pins the `bats` version — run `mise install` once, then `mise run test`.

Skills (`.claude/skills/shared-agent-memory-setup`, `.claude/skills/shared-agent-memory-migrate`, `.claude/skills/shared-agent-memory-uninstall`, `.claude/skills/shared-agent-memory-cross-project`) aren't covered here — they're prose instructions an agent interprets, not deterministic scripts, so unit tests don't apply. Their real validation is a live migration trial against an actual host's existing memory stores. See [`VERIFICATION.md`](VERIFICATION.md) for the checklist of scenarios that need a real run to confirm, and which have already had one.

## Structure

- `core/` — agent-agnostic pieces: project key resolution, the shared-root layout convention, and lock semantics. No dependency on any specific coding agent.
- `adapters/` — thin integrations that wire the core mechanism into a specific agent's actual memory path and lifecycle hooks.
  - `adapters/claude-code/hooks/` — the `SessionStart`/`Stop` hook scripts Claude Code's `shared-agent-memory-setup` skill registers.
- `.claude/skills/` — the Claude Code skills themselves (`shared-agent-memory-setup`, `shared-agent-memory-migrate`, `shared-agent-memory-uninstall`, `shared-agent-memory-cross-project`) — prefixed to avoid colliding with any other tool's own generically-named skills once symlinked into the user's global `~/.claude/skills/`. Kept at the repo root, not under `adapters/`, because that's the specific path Claude Code auto-discovers project-scoped skills from.
- `docs/` — design notes.

## Want something different?

This bakes in a specific set of trade-offs (see Non-goals above) that may not fit your setup. Two ways to go from here:

- **Fork it.** The core/adapter split exists so you can point an agent at your fork and have it build out what's specific to your needs — a different agent adapter, a different transport than Syncthing, a different behavior-layering model.
- **Open an issue.** Suggestions and bug reports are welcome.

## Status

Early but working. `core/` (key resolution, symlinking, advisory locking, the `_personal` and `_unresolved` buckets) and the Claude Code `SessionStart`/`Stop` hooks are built and tested, and have been run for real: hooks are registered on multiple live hosts, several per-project and mixed home-directory stores have been migrated into the shared root, and Syncthing has synced the shared root bidirectionally between two real hosts — not just exercised in isolation. Still missing: status/observability tooling, and a hook-run logging strategy.

## License

MIT — see `LICENSE`.
