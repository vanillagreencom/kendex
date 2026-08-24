---
name: worktree
description: "Git worktree management: create, list, remove isolated working copies with env/config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] [--reuse|--restack|--recover-local] [--replay] | restack continue|skip|abort <ID|path> | list | remove <ID|path>"
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
| `create` | Claim a new issue worktree. Bare `create <ID>` is a new-work claim, not a discovery command: existing ownership (worktree, branch, or PR) exits 75 and leaves local branches unchanged — inspect or monitor owned work instead of spawning a second implementer. Reuse, conflict recovery, and `--recover-local`: `create --help` |
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

## Recovering a broken `.agents` link

Route by shape, not by whether `test -L .agents` passes — the routing table and the tracked-content link mechanics are under `fix-links --help`. Run `fix-links` **from the main checkout**: the worktree's own copy of the script is reached *through* the broken link. Until it is fixed, do not trust that tree for local verification.

**Consumers: carry this inline in the tracked `AGENTS.md` / `CLAUDE.md`; do not point here** (this section is read *through* `.agents`). Copy it verbatim:

```text
Broken `.agents` in a worktree (missing, or a real directory): from the MAIN checkout run
`.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` — never from the worktree,
and never `git checkout -- .agents` (the path holds no tracked content, so the command
changes nothing while the link stays broken). A genuinely corrupt tracked file is the other
case: `git checkout -- <path>`, run in the checkout the file really lives in (the main
checkout when the path sits under a configured symlink).
```

## Session guard (ownership leases)

`scripts/worktree-session-guard` stops cleanup from destroying a worktree a session is still working in; the lease is a native Git worktree lock whose reason line carries the owner and heartbeat. Claiming is the caller's job: `create` never claims, the orchestrating workflow claims once the worktree is the session's, and `remove` releases at teardown. Probe with `status` (read-only), never `claim` — `claim` takes or rewrites the lease. Commands, exit codes, `--repo` scope, and staleness caveats: `worktree-session-guard --help`; the guard's limits: [references/session-guard.md](references/session-guard.md).

## System Dependencies

`git`; authenticated `gh` for new-work PR ownership discovery; `flock` for repository-local per-issue claim serialization (the session guard prefers it and falls back to a `mkdir` mutex without it); Bash 3.2+ (macOS system bash is supported).

## Configuration

Set non-sensitive defaults in committed `kendex.settings.toml` under `[env]`; existing `.env` and `.env.local` variables still work, and `.env.local` wins for secrets or personal overrides. **Symlink untracked paths only** — an entry that shadows tracked files is linked per untracked child instead (`fix-links --help`). Variable semantics and setup-path hardening: `worktree --help`.
