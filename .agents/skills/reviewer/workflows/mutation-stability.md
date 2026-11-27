# Mutation-stability pairing

Read [Mutation-Stability Pairing](../SKILL.md#mutation-stability-pairing) before preparing or running this probe.

## 1. Prepare copies

- For a probe that needs any revision's files, create a directory of your own outside the worktree and the common Git directory with `dir=$(mktemp -d "${TMPDIR:-/tmp}/review-copy.XXXXXX")`.
- Use `/tmp` in place of a `TMPDIR` that resolves inside `git rev-parse --show-toplevel` or `--git-common-dir`.
- Redirect `git show REV:PATH` to a file there for a single file, or extract tracked files there with `git archive REV | tar -x -C "$dir"`.
- Before extracting, compare the free space `df -Pk "$dir"` reports with the tracked files' size (`git ls-tree -r -l REV`) plus the size of the worktree's build output if the probe builds in the copy. The build writes its own `target/` beside the copied source.
- Take a copy only if it fits.
- Keep other revisions' bytes out of the shared tree throughout the probe.
- For controls, apply [code-quality § Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards).
- Remove the probe directory and its build output before returning.

`mutation-stability` takes the worktree itself as `--worktree`. It extracts a clean and a mutant copy of `--sha` under its own `mktemp -d` on the base above, runs the test in each, and removes them on exit unless `--keep` or a cleanup that reports `workspace kept`.

The script makes the size check itself before it extracts either copy. It refuses `disk-space-short`, naming the need and the free space, when two copies and headroom do not fit. Its build-output term counts only output already in the worktree: where the worktree has not yet built what `--build` writes, allow for a fresh build in each copy yourself. See `mutation-stability --help` for what it counts.

## 2. Run the probe

```bash
.agents/skills/reviewer/scripts/mutation-stability --worktree [WORKTREE_PATH] --sha [SHA] --test '[TEST_CMD]' --build '[BUILD_CMD]' --mutate '[MUTATE_CMD]' --stability [SAMPLE_COUNT]
```

- Use `--stability 1` for a missing control.
- Repeated clean runs need a named concurrency failure to investigate.
- `TEST_CMD` takes the control scope [code-quality § Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards) sets.
- See `mutation-stability --help` for the sample and timeout bounds.

## 3. Await completion

- A call that can outlast one foreground tool call runs through the orch job runner per [orch waiter-launch.md](../../orch/references/waiter-launch.md) § Launch.
- Take its `[RUN_DIR]` from `mktemp -d "${TMPDIR:-/tmp}/waiter.XXXXXX"` on the copy base in [§ 1](#1-prepare-copies), in place of the worktree's `tmp/`, where an active `reviewer-read-only` hook refuses the job's writes.
- Wait for its end inside your own turn, never through the monitor in waiter-launch.md § Completion.
- Run the foreground poll `sh -c 'bound=$(command -v timeout || command -v gtimeout) || { printf "%s\n" "reviewer: missing-command commands=timeout,gtimeout" >&2; exit 127; }; exec "$bound" "$@"' sh 540 sh -c 'until test -s "[RUN_DIR]/wait.exit"; do sleep 30; done'` under the harness's maximum command timeout.
- Run it again for as long as it exits 124.
- Never end the turn while `wait.exit` is empty, and never wait for a completion notice: a subagent whose turn has ended is not woken when the run ends.
- Then read `wait.exit`, whose nonzero code stays nonzero, and the `mutation: … stability: …` line in `[RUN_DIR]/wait.log`.
- Never wait on `pgrep -f` or `ps | grep` of the command: the pattern also stands in the waiting shell's own command line, so the wait matches itself and never sees the run end.
