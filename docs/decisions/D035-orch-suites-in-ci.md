# D035: The orch suites run in the merge group again

[← Decision Index](INDEX.md)

**Date**: 2026-11-16

**Status**: Active

**Research**: [KEN-4687](https://linear.app/vanillagreen/issue/KEN-4687); Jarvis decision of 2026-11-16 (session 509), under the owner's delegation

**Supersedes**: [D026](D026-macos-native-contracts.md) and [D027](D027-merge-queue-proves-every-change.md) in part, their **Applies to** exception for one point: [KEN-4718](https://linear.app/vanillagreen/issue/KEN-4718)'s temporary removal of the orch test corpus from CI.

**Decision**: The orch suites run in CI again, in the shards `orch-state` and `orch-rest` of `.github/workflows/skill-tests.yml`, which `tools/ci-job-set` names as `ORCH_SHARDS`. `skills/orch/tests/run-all.sh`'s `shard_of` splits them: `orch-state` runs the orch suites whose names contain `lane`, and `orch-rest` runs every other orch suite and, on its Linux leg, the package runtimes' Rust targets the reach selects. `orch-state` and `orch-rest` each run on a `merge_group` event and on a `push` to `main`, on Linux in the `skill-suites-shard` job and on macOS in `skill-suites-macos-queue`, and on macOS alone on `schedule` and `workflow_dispatch` in `skill-suites-macos`; neither runs on `pull_request`. A merge group runs the orch shards its change's suite reach selects, and a push to `main` runs only the suites its same-head merge group left unproved. [D026](D026-macos-native-contracts.md) tracks the independent entries' restoration and the remaining adopter exception. For a change of a measured class (`micro`, `small` or `standard`) whose lane round CI admits, the round's validation runs `tools/guard`'s checks and no suite (KEN-5253): the merge group is the only place its suites run, and the adopter still runs after merge. A round CI does not admit runs the suites its changed files reach by `tools/guard`'s range selection. A declared settings key with no named test reader can select its tree's whole suite set in a scoped round while the merge group's unscoped path reach omits that tree.

**Why**: D026 and D027 each name the corpus's restoration as their revisit condition, and the rebuild restores it; Jarvis ruled that this ends KEN-4718's exception for the orch corpus. D027 keeps the merge-queue run as the proof of a kendex change. A pull-request push runs no product CI.

**Rejected**: Keeping KEN-4718's exception for the orch corpus, under which orch regressions have no CI proof (D026, D027).

**Revisit when**: A change takes an orch suite out of the merge group's reach.
