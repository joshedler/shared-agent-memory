# Project key resolution

Every session's memory lives in one bucket under the shared root, named by the project's key. The goal: however and wherever a repo is cloned, its sessions land in the same bucket on every host. This note explains how a key is chosen, which edge cases are handled and how, and what was considered and deferred.

Items marked _(planned)_ are designed but not built yet.

## How a key is chosen

A session's bucket comes from the first of these that applies. `core/resolve-key.sh` handles 1–3 and exits nonzero if none of them apply; the session-start hook handles 4:

1. **The `origin` remote URL**, normalized:
   - The scheme, a leading `git@` user and a trailing `.git` are dropped, `host:owner/repo` becomes `host/owner/repo`, and the result is lowercased. `https://github.com/o/r.git`, `git@github.com:o/r.git` and `ssh://git@github.com/o/r.git` all become `github.com/o/r`.
   - For ssh-style remotes (`user@host:…` or `ssh://…`), the host is passed through `ssh -G <host>` and replaced by the `hostname` it reports. This maps per-host ssh config aliases (for example a deploy-key alias like `Host github.com-myrepo`) to the real host. `ssh -G` only prints the effective configuration and never connects, but it does evaluate any `Match exec` blocks in your ssh config, so those commands run whenever a key is resolved. If `ssh` is missing or fails, the host is kept as written. https remotes never call `ssh`.
   - A port in an `ssh://` URL is dropped, so `ssh://git@github.com:2222/o/r.git` is `github.com/o/r` too.
2. **A `.claude-project-id` marker file** at the git root (or the directory itself outside a repo). Its trimmed content is the key.
3. **`$HOME` itself** resolves to the reserved `_personal` key.
4. **Anything else:** when `resolve-key.sh` finds nothing, the session-start hook falls back to the synthetic key `_unresolved/<native-slug>`, where the slug is the agent's own encoding of this host's directory path. It isn't shared identity, just a place to keep memory until the directory gets a remote or a marker.

## Edge cases

### Handled automatically

| Case | How |
|---|---|
| https vs ssh clone | Both normalize to the same key. |
| ssh config host alias | `ssh -G` maps it to the real host. |
| Port in an `ssh://` URL | Dropped during normalization. |
| Worktrees, second clones, differently named checkout directories | Same remote, so same key; the checkout's location never matters. |

### Caught when it happens

| Case | How |
|---|---|
| A directory in `_unresolved` later gets a remote or marker | `link-memory.sh` refuses to move the link away from a bucket that still has content, and the session reports it with a pointer to the migrate skill, which moves or merges the memory with you reviewing it. If the old bucket is empty (a leftover `.lock` doesn't count), the link moves quietly and nothing is lost. |
| _(planned)_ Any new bucket being created | The session announces it, so an unexpected new bucket for a project that already has memory is visible right away. |

### Caught at review time _(planned)_

When the hook creates a bucket it writes a small identity file inside it: the repo's root commit (if it has one) and the remote URL as that host saw it. Buckets created before this existed get one on their next session. The file is written once, into that bucket only, so hosts never write the same file.

The review skill's checker uses these to report:

- **Empty buckets**, usually left behind by a link that moved, or by a key that was computed wrongly and later fixed.
- **Buckets that share a root commit.** The checker doesn't decide; it asks whether they're the same project. Forks and projects started from a starter repo legitimately share history and should stay separate. If you say they're the same, the merge goes through the migrate skill.

This covers the cases a URL can't: a fork cloned as `origin`, a renamed or transferred repo, a mirror on another forge, or a remote spelled differently on another host.

## Considered and deferred

- **The root commit as the key itself.** It's identical however a repo is cloned, but forks and template-born projects share it, so unrelated projects would share memory.
- **A root-commit lookup at session start** (a `_roots/<hash>/<key>` index plus write-once `_aliases/<key>` redirects, asking you when a new key's history matches an existing bucket). It would catch duplicates before any memory is written, but it needs a provisional link while waiting for your answer, needs an answer recorded per key, and handles the new-repo case badly. Review-time detection plus the new-bucket announcement covers the same cases with far less machinery. Worth revisiting if splits turn out to happen often enough that catching them at review is too late.
- **Remembering "these are separate."** A review answer that two buckets sharing a root commit are different projects should eventually stop the same pair being flagged again. Not designed yet.
- **A port in an `http(s)://` URL.** Only `ssh://` ports are dropped today, so `https://git.example.com:8443/o/r.git` becomes `git.example.com/8443/o/r` and won't match an ssh clone of the same repo. To do: drop it the same way, test first.
- **An ssh user other than `git@`.** Only a leading `git@` is dropped, so `alice@git.example.com:o/r.git` or `ssh://alice@git.example.com/o/r.git` becomes `alice@git.example.com/o/r` and won't match an https clone of the same repo. To do: drop any `user@`, test first.
- **A gentler prompt for moving an `_unresolved` bucket**, in place of today's refusal message. Optional polish; nothing is lost without it.
