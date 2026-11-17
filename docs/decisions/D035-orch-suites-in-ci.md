# D035: The orch suites run in the merge group again

[← Decision Index](INDEX.md)

**Date**: 2026-11-16

**Status**: Active

**Research**: [KEN-4687](https://linear.app/vanillagreen/issue/KEN-4687); Jarvis decision of 2026-11-16 (session 509), under the owner's delegation

**Supersedes**: [D026](D026-macos-native-contracts.md) and [D027](D027-merge-queue-proves-every-change.md) in part, their **Applies to** exception for one point: [KEN-4718](https://linear.app/vanillagreen/issue/KEN-4718)'s temporary removal of the orch test corpus from CI.

**Decision**: The orch suites run in CI again, in the shards `orch-state` and `orch-rest` of `.github/workflows/skill-tests.yml`, which `tools/ci-job-set` names as `ORCH_SHARDS`. `skills/orch/tests/run-all.sh`'s `shard_of` splits them: `orch-state` runs the orch suites whose names contain `lane`, and `orch-rest` runs every other orch suite and, on its Linux leg, the package runtimes' Rust targets the reach selects. `orch-state` and `orch-rest` each run on a `merge_group` event and on a `push` to `main`, on Linux in the `skill-suites-shard` job and on macOS in `skill-suites-macos-queue`, and on macOS alone on `schedule` and `workflow_dispatch` in `skill-suites-macos`; neither runs on `pull_request`. A merge group runs the orch shards its change's suite reach selects, and a push to `main` runs only the suites its same-head merge group left unproved. Four entries stay main-only: `critical-path-deny.test`, `orch-shard-partition.test`, `pi-agents-tmux` and `adopt-refresh.test`. The `skill-suites-main-only` job runs each alone on a `push` to `main`, outside required `CI`, and the merge-group legs leave them out. For a change of a measured class (`micro`, `small` or `standard`), an orch suite a lane's validation runs runs again in that change's merge group: the lane's `tools/guard` run selects suites by the reach that `tools/ci-job-set` projects onto the shards.

**Why**: D026 and D027 each name the corpus's restoration as their revisit condition, and the rebuild restores it; Jarvis ruled that this ends KEN-4718's exception for the orch corpus. Every other line of D026 and D027 stands, the owner's ruling in D027 among them: the merge-queue run is the only proof of a kendex change, and a pull-request push runs no product CI.

**Rejected**: Keeping KEN-4718's exception for the orch corpus, under which orch regressions have no CI proof (D026, D027).

**Revisit when**: A change takes an orch suite out of the merge group's reach, or moves one of the four main-only entries into the merge group.
