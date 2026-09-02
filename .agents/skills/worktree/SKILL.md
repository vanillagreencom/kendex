---
name: worktree
description: "Load to create, list, remove, push, or repair a git worktree."
summary: "Git worktree management: create, list, remove isolated working copies with env and config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] [--reuse|--restack] [--replay] | restack continue|skip|abort <ID|path> | list | remove <ID|path>"
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [git]
---

# Worktree Management

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

```bash
.agents/skills/worktree/scripts/worktree <command> [options]
```

Worktrees live at `<parent-of-checkout>/.worktrees/<checkout-name>/{id}`, outside the repo root. Every command's contract — flags, exit codes, failure semantics, recovery — is its `--help`; the top-level `worktree --help` carries the command index, path and issue-ID rules, configuration variables, and setup-path hardening.

## Commands

| Command | Description |
|---------|-------------|
| `create` | Claim a new issue worktree — a new-work claim, not a discovery command: existing ownership exits 75, and owned work is inspected or monitored, never given a second implementer. Reuse and conflict recovery: `create --help` |
| `restack` | Guardedly continue, skip, or abort a tool-created paused restack |
| `list` | List all worktrees |
| `remove` | Remove worktree, clean symlinks, prune branches |
| `cleanup` | Remove worktrees whose branches are merged |
| `path` / `exists` | Print / check the worktree path for an issue ID |
| `check` | Pre-create git state check (JSON: uncommitted, unpushed) |
| `push` | Push worktree branch with auto-rebase and pinned `--force-with-lease`; the `rebase-map:` contract for remapping pre-rebase SHAs is in `push --help` |
| `fix-links` / `repair-links` | Restore configured symlinks; `repair-links` is the git-hook-driven variant that never destroys untracked data |
| `codex-setup` / `codex-branch` / `codex-cleanup`, `claude-setup` / `claude-cleanup` | App-created worktree hooks — installation wiring: [references/hooks.md](references/hooks.md) |

### Policy-blocked rebase (cherry-pick replay fallback)

When an execution policy rejects top-level `git rebase` porcelain, never retry the porcelain and never substitute a raw `--force` push — add `--replay` to the guarded restack (`create --help`); the controls stay `restack continue|skip|abort <ID>`.

## Recovering a broken `.agents` entry

Route by shape, not by whether `test -L .agents` passes. Ask both indexes what sits under the path — `git -C <worktree> ls-files -- '.agents/'`, and the same command against the main checkout. The trailing slash is the query: descendants decide the layout, and the entry itself does not count. Neither index alone decides: a branch can add the render ahead of main, or trail the commit that started tracking it. Reading one index routes a healthy tree to the untracked-only repair, where `fix-links` produces no symlink and the operator loops on a command that changed nothing. Both answer while the path itself is broken:

- **Either non-empty** — the repo commits its render, and `.agents` is a REAL DIRECTORY by design: the tracked files, plus one symlink per untracked child, except an untracked `.gitignore`, which is a copy of main's file. A child missing its link, or a real path where a link belongs, is `fix-links`. A modified or corrupt TRACKED file is `git checkout -- <path>`, run in the checkout the file really lives in — the main checkout when the path sits under a configured symlink, the worktree otherwise.
- **Both empty** — the entry is untracked-only and must itself be a symlink. `fix-links` is the repair; with no tracked content at the path, `git checkout -- .agents` changes nothing while the link stays broken.

`fix-links` reads its sources from the main checkout wherever it is invoked, and only the main checkout's copy of the script is guaranteed intact — a worktree copy reached *through* the entry being repaired may be among the missing files. Run `.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` from the main checkout; name the target, since a bare invocation there resolves to the main checkout and is refused. Until the entry is fixed, do not trust that tree for local verification. It reports success only when every configured entry ended healthy; a non-zero exit names the paths it did not restore, so read them rather than re-running the same command. Routing table and link mechanics: `fix-links --help`.

Consumers wanting this locally get a pointer, never a copy. One line resolves the main checkout from any worktree, at any depth, and prints this file: `cat "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"/.agents/skills/worktree/SKILL.md`. A verbatim copy in a tracked `AGENTS.md` / `CLAUDE.md` is out of `kendex refresh`'s reach and goes stale silently.

## Session guard (ownership leases)

`scripts/worktree-session-guard` stops cleanup from destroying a worktree a session is still working in; the lease is a native Git worktree lock whose reason line carries the owner and heartbeat. Claiming is the caller's job: `create` never claims, the orchestrating workflow claims once the worktree is the session's, and `remove` releases at teardown. Probe with `status` (read-only), never `claim` — `claim` takes or rewrites the lease. Commands, exit codes, `--repo` scope, and staleness caveats: `worktree-session-guard --help`; the guard's limits: [references/session-guard.md](references/session-guard.md).

## JS Dependencies

`worktree --help` § Dependencies owns install and linked-`node_modules` behavior.

## System Dependencies

`git`; authenticated `gh` for new-work PR ownership discovery and for proving a squash-merged branch merged in `cleanup` and `remove`; `flock` for repository-local per-issue claim serialization; Bash 3.2+ (macOS system bash is supported).

## Configuration

Set non-sensitive defaults in committed `kendex.settings.toml` under `[env]`; `.env.local` wins for secrets or personal overrides, and a `.env` file is never read. **Symlink only what git does not carry** — an entry does nothing when git carries every path under it, and a directory holding tracked content stays a real directory with its untracked children linked, bar an untracked `.gitignore`, which is copied (`fix-links --help`). Variable semantics and setup-path hardening: `worktree --help`.
