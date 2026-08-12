# Performance QA Reference

Benchmark execution, regression classification, and recording rules for the performance QA agent. Loaded on demand from `workflows/qa-review.md` § 2 — other reviewers never need this file. Everything here is operational contract, not technique: thresholds and hot/cold-path definitions come from the project's docs, and generic profiling knowledge is assumed.

## Regression Classification

- When the project benchmarking skill's regression check exits non-zero, classify **every** regressed operation using that skill's rules — silent omission is forbidden. Populate `blockers[]` and `qa_metadata.perf_qa.regressions[]` accordingly.
- If a targeted regression command reports numeric regressions but an aggregate validation command passes, classify and report the targeted numeric regressions; the aggregate result is supporting context, not a substitute.

## Benchmark Execution and Recording

- Use the project benchmarking skill's direct runner or recorder commands only when documented as standalone commands. Do not use shell pipelines, redirection, heredocs, `tee`, `cat >`, inline env assignment, command substitution, or shell plumbing to capture or record benchmark output (orch SKILL.md § Harness-Safe Shell). If the only documented recording path requires shell plumbing, stop and report the harness gap; if manual entry is supported, pass data only via a documented direct argument or body-file option.
- Feature-gated benchmark targets count: a bare `cargo bench` is not a "full benchmark" run when active lanes require features such as `live-feeds` or `ui-bridge`.
- If the parser records zero results, stop and report the harness gap instead of counting the run as coverage. Common causes: missing required features, parser prefix drift after bench refactors, tool output format changes.
- If the benchmark recorder fails closed on all-zero counters, report a benchmark environment/tooling failure with command, commit, and error evidence; set `benchmark_commit` to `"none"`; never bypass with manual data.
- Benchmark results may be symlinked to the main repo in worktrees — writes land in main's directory, no commit needed. Record the worktree branch's latest commit SHA as `benchmark_commit`.
