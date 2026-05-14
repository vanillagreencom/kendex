# Flightdeck TS Port — Progress + Continuation

Worktree: `/mnt/Tertiary/dev/vstack/flightdeck-ts-port`
Branch:   `flightdeck-ts-port`
Base:     `76be4f1` on `main`
Plan:     `/mnt/Tertiary/dev/vstack/main/tmp/flightdeck-ts-port-plan.md`

## Status (session 2)

**106 tests pass across 14 files. 0 fail.** Session 2 cleared the deferred review punchlist (parallel-groups race, jq variabilization, .env loader parity, project-root memo, state-dir memo, dep preflight, signal handlers), applied the 21-finding doc audit, and laid foundation modules for the daemon `start` port (log/gc/wake-payload with unit tests). The daemon run-loop + subscriber lifecycle remain bash — same scope decision as session 1, now reflected with first-class TS leaves that the next iteration can compose into a TS run loop.

```
$ cd skills/flightdeck/lib/flightdeck-core && bun test
 106 pass
 0 fail
 229 expect() calls
Ran 106 tests across 14 files.
```

## Status (session 1, retained)

81 parity tests pass across 9 files. All eight bash scripts targeted for porting now have a TS sibling under the trampoline gate; default remains bash for every script. The daemon `start` action has since landed as a parity-tested TS run-loop + subscriber lifecycle (see below); its **runtime default** still forwards to the bash sibling until one full production cycle on TS, gated by `FLIGHTDECK_USE_TS_DAEMON_START=1` (or global `FLIGHTDECK_USE_TS=1`).

## Ports landed (with commit + parity scope)

| Script | Bash LOC | TS file | Tests | Commit |
|---|---|---|---|---|
| `prompt-classify` | 206 | `src/bin/prompt-classify.ts` + `classifier/{rules,classify}.ts` | 23 fixture tags | `1b1ea7b` |
| `flightdeck-state` | 359 | `src/bin/flightdeck-state.ts` + `state/master-state.ts` | 7 (init/idempotent/set/get/append/increment/archive) | `1b1ea7b` |
| `parallel-groups` | 221 | `src/bin/parallel-groups.ts` | 7 (read/write/clear/lookup/needs-refresh/CSV gaps) | `59d7706` |
| `lib/{oc,cc,pi,codex}-paths.sh` | 857 | `src/paths/{oc,cc,pi,codex}.ts` + `src/paths/daemon.ts` | 4 parity pure-function (cc_encode_cwd, cc_uuid_for_issue, oc_issue_from_pane_target, fd_session_key_from_id) | `accf2a0` |
| `pane-registry` | 548 | `src/bin/pane-registry.ts` | 8 (init/set-state/log-decision/get/list/find-by-pane/remove + invalid-state rejection) | `51a1fcd` |
| `pane-poll` | 533 | `src/bin/pane-poll.ts` | 5 (dead-pane × 2 + empty-batch + dead-batch-row + non-array stdin) | `b8d46c8` |
| `pane-respond` | 853 | `src/bin/pane-respond.ts` | 13 validation (target/option/option-multi/keys/question/payload-tag/answers-json/answer-text/unknown-flag) | `c2fca9b` |
| `flightdeck-daemon` (CLI surface) | 2434 (port covers ~700) | `src/bin/flightdeck-daemon.ts` | 6 (status/find-window/health/stop on no-daemon + missing-session + unknown-action) | `2dc616f` |

Adds up to ~6000 LOC bash → ~3500 LOC TS so far.

## Out of scope this session

**Daemon `start` action — TS port landed, bash still the runtime default.** Session 2 left the run-loop unported; subsequent sessions completed it. `src/daemon/loop.ts`, `src/daemon/lifecycle.ts`, and `src/daemon/subscribers/{spawn,drain,index}.ts` are on `main` with parity tests, and the TS `start` action runs end-to-end when `FLIGHTDECK_USE_TS_DAEMON_START=1` is set. The bash sibling remains the unflagged default until one full production cycle on TS validates the port — same opt-in / opt-out pattern every other script uses. See `SKILL.md` § Scripts for the current gating language.

## Infrastructure landed

- `skills/flightdeck/lib/flightdeck-core/`
  - `package.json` — private bun TS package
  - `tsconfig.json` — strict, ES2023, bundler module resolution, allowImportingTsExtensions
  - `bun.lock` — pinned devDeps (typescript 5.9, @types/bun)
  - `src/` — `bin/` (CLI entries), `classifier/`, `state/`, `paths/`, `shared/`
  - `tests/parity/` — eight parity test files
  - `tests/unit/` — paths helper unit tests
- Trampoline at `scripts/<name>`: dispatches `bash` ↔ `ts` based on
  `FLIGHTDECK_USE_TS_<UPPER>=1` (or global `FLIGHTDECK_USE_TS=1`).
  Bash bodies preserved as `scripts/<name>.bash`.

## Patterns established

1. **Trampoline copy** — same body for every trampoline; derives env var from `$0`. Adding a new port = `mv scripts/X scripts/X.bash && cp scripts/prompt-classify scripts/X`.
2. **Parity test shape** — `run(useTs, ...)` returns stdout/stderr/status; assert each.
3. **jq subprocess for filter parity** — instead of re-implementing jq paths in JS, shell out to `jq` for state CRUD. Preserves identical semantics; revisit for performance only if a hot path emerges.
4. **Adapter freshness probes cached** — `fd_adapter_freshness_cache_{get,set}` in `paths/daemon.ts` mirrors the bash cache.

## Gotchas hit (recorded so the daemon port avoids them)

1. **Bash positional vs flag order** — many scripts parse `<action>` before flags. Always `[action, ...flags]` in test invocations.
2. **Script-location project root** — `parallel-groups` resolves project root from `$SCRIPT_DIR`, not cwd. Tests pin via `ORCH_CACHE_DIR`; the TS port uses cwd (cleaner — the bash quirk stays as-is).
3. **Trailing newlines** — bash `jq -c` always adds `\n`; TS direct returns need explicit `"\n"`.
4. **pane-base-index** — `tmux show-options -g pane-base-index` defaults to 0 unless user config sets 1. Tests pin `--pane-index 0` explicitly for determinism.
5. **TS narrow-type bug** — `argv[0] === "--batch"` then later `(src as string) === "-"`; TS's narrowing locks the const string literal type. Cast through string.
6. **`tmux display-message -t <bogus>`** silently returns the active pane's id. Always gate on `tmux list-panes -t <target>` first.

## Session 2 deliverables (commits since `69cda24`)

- `cf8822e` — parallel-groups race + jq --arg variabilization. cmdWrite/cmdClear now hold flock for the full read+next-id+merge+write window. Adds 10-writer stress test.
- `5239b22` — .env loader parity + project-root memoization. Shells out to `set -a; source ...; env -0` for true bash parity (\${VAR:-fallback}, \$VAR). Caches project root per-process.
- `fe5b3eb` — dep preflight + SIGINT/SIGTERM/SIGHUP handlers + state-dir memoization. New `src/shared/preflight.ts` with `preflightDeps()` and `onShutdown()`; wired into flightdeck-daemon CLI startup.
- `53e1256` — doc-audit punchlist (21 findings across SKILL.md, README.md, tests/README.md, two pattern docs, two workflow docs, pi-flightdeck README, AGENTS.md).
- `<this>` — daemon helper foundation: `src/daemon/{log,gc,wake-payload}.ts` with unit tests. Not yet reachable from the running daemon (still forwards to bash); later sessions composed them into the TS run loop now living at `src/daemon/{loop,lifecycle}.ts` + `src/daemon/subscribers/{spawn,drain,index}.ts` (gated on `FLIGHTDECK_USE_TS_DAEMON_START=1`).

## Remaining work

| Phase | Task | Notes |
|---|---|---|
| landed | Daemon run_loop + subscribers + wake delivery | TS port lives at `src/daemon/{loop,lifecycle}.ts` + `src/daemon/subscribers/{spawn,drain,index}.ts` with parity tests. Subscribers delegate the long-running bodies to `scripts/lib/subscribers.bash` so bash and TS daemons share one canonical implementation. Runtime default still forwards to bash until one full production cycle on `FLIGHTDECK_USE_TS_DAEMON_START=1`. |
| execute | Async pane-poll batch (review-perf critical) | Needs the `Bun.spawn` async refactor; the daemon run-loop port made the structural changes that unblock this. |
| execute | Native jq replacement for `*_LAST_ASSISTANT_JQ` (review-perf important) | Pair with async refactor; keep jq constants exported for parity-test corpus. |
| execute | Freshness probe fold into read (review-perf important) | Same async refactor. |
| test | Integration smoke under `FLIGHTDECK_USE_TS=1` | Extend `tests/live-wake.sh` to assert against TS path. Needs a live pi + tmux session. |
| review | Re-review by sub-pi reviewer agents | After daemon run-loop port lands. |
| wrap | Merge prep | Flip per-script defaults to TS in trampolines AFTER live test green AND review findings resolved; delete `.bash` siblings after a stable production cycle. |

## Quickstart for next session

```bash
cd /mnt/Tertiary/dev/vstack/flightdeck-ts-port/skills/flightdeck/lib/flightdeck-core
bun test          # confirm parity suite still green
bun run typecheck # confirm clean

# The daemon run-loop port has landed; remaining work is the
# async pane-poll refactor + flipping per-script defaults to TS.
# Run the live integration test under each individual flip before
# changing the trampoline default:
FLIGHTDECK_USE_TS_PROMPT_CLASSIFY=1 ./tests/live-wake.sh
FLIGHTDECK_USE_TS_FLIGHTDECK_STATE=1 FLIGHTDECK_USE_TS_PROMPT_CLASSIFY=1 ./tests/live-wake.sh
FLIGHTDECK_USE_TS_DAEMON_START=1 ./tests/live-wake.sh
# ... etc
```

## Decisions for the next session

- **`flock(1)` strategy for the daemon run_loop**. TS daemon will hold session-lock across event drains; need to confirm `spawnSync("flock", ["-x", fd, "true"])` pattern actually holds the lock for the parent process's lifetime, or move to `Bun.flock` which is per-fd in the same process.
- **Subscriber spawn model**. Bash uses `setsid nohup ... &` for detached subscribers. TS can use `Bun.spawn({ detached: true, stdio: ["ignore", logFd, logFd] })`. Need a test that subscriber children survive the daemon exit and aren't orphaned.
- **Wake delivery for pi master**. Already routed through `pi-bridge send --pid <master_pid>` in the bash daemon. Direct subprocess call in TS — straightforward.
