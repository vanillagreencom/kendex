# Mutation-stability pairing

Read [Mutation-Stability Pairing](../SKILL.md#mutation-stability-pairing) before preparing or running this probe.

## 1. Prepare copies

The script takes the worktree itself as `--worktree`, extracts a clean and a mutant copy of `--sha` under its own `mktemp -d` on the [§ Ethos](../SKILL.md#ethos) base, runs the test in each, and removes them on exit unless `--keep` or a cleanup that reports `workspace kept`; before the call, run the [§ Ethos](../SKILL.md#ethos) free-space check for two copies, each with its build output.

## 2. Run the probe

```bash
.agents/skills/reviewer/scripts/mutation-stability --worktree [WORKTREE_PATH] --sha [SHA] --test '[TEST_CMD]' --build '[BUILD_CMD]' --mutate '[MUTATE_CMD]' --stability [SAMPLE_COUNT]
```

- Use `--stability 1` for a missing control. Repeated clean runs need a named concurrency failure to investigate. `TEST_CMD` takes the control scope [code-quality § Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards) sets. Clean repeats stop starting after `--stability-budget` seconds, with at least two completed runs unless `--stability` is 1, and at most `--stability` runs. A started run keeps `--timeout`, so the stability phase is bounded by budget plus two timeouts, excluding extraction and cleanup. The defaults are 60 seconds and 300 seconds.

## 3. Await completion

A call that can outlast one foreground tool call runs through the orch job runner per [orch waiter-launch.md](../../orch/references/waiter-launch.md) § Launch, with `[RUN_DIR]` from `mktemp -d "${TMPDIR:-/tmp}/waiter.XXXXXX"` on the [§ Ethos](../SKILL.md#ethos) base in place of the worktree's `tmp/`, where the `reviewer-read-only` hook refuses the `launch.sh` write. Wait for its end inside your own turn, never through § Completion's monitor: run the foreground poll `sh -c 'bound=$(command -v timeout || command -v gtimeout) || { printf "%s\n" "reviewer: missing-command commands=timeout,gtimeout" >&2; exit 127; }; exec "$bound" "$@"' sh 540 sh -c 'until test -s "[RUN_DIR]/wait.exit"; do sleep 30; done'` under the harness's maximum command timeout, and run it again for as long as it exits 124. Never end the turn while `wait.exit` is empty and never wait for a completion notice: a subagent whose turn has ended is not woken when the run ends. Then read `wait.exit`, whose nonzero code stays nonzero, and the `mutation: … stability: …` line in `[RUN_DIR]/wait.log`. Never wait on `pgrep -f` or `ps | grep` of the command: the pattern also stands in the waiting shell's own command line, so the wait matches itself and never sees the run end.
