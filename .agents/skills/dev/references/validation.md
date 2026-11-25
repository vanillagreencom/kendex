# Dev round validation

Read when a dev round runs its validation gate ([dev-implement.md § 5](../workflows/dev-implement.md#5-validate)), when a workflow routes a validation refusal, a `no-verdict` or a failure, or when a check reads a round's Validation Routes rows.

## The gate

The validation gate is this complete list:

- § Admission, where the delegation carries a `Validation admission:` line.
- § Validation entry.
- § Verification scope.
- § Must-fail controls.
- § Foreground route, in place of the runner, for a project whose own policy forbids orch's validation runner.
- § No-verdict.
- § Apple gate.
- After the dev agent returns its local result, the orchestrator gets green CI and a passing review gate. The dev agent does not claim or reproduce these downstream results.

For this validation gate, run no proof, rerun, receipt, isolation step, or approval step outside this list. Investigation runs follow [dev SKILL.md § Validation](../SKILL.md#validation). If an agent believes the list misses a rule, it records the proposal once under `### Proposed Rules` in the completion summary and in the matching return line. The orchestrator puts it once in the PR body. Neither role performs the proposed rule.

## Admission

When the delegation carries a `Validation admission:` line, run that exact command before every validation start of this round, including a rerun this gate permits.

- It records the run's admission in the orchestrator's state before any work starts and prints one JSON reply.
- Pass the reply's `.result.report.run_id` to the start as `--run-id [RUN_ID]`, so the run's directory is the one the admission named.
- The command is idempotent: run again before the first start, it names the same run.
- Before a rerun this gate permits, add `"attempt": "next"` to the request file the line names, with the harness file tool, then run the command. The reply names the rerun's own run id, and the first run keeps its record.
- A reply whose `ok` is false, or a command that cannot run, stops the round before validation: report its keyed line.
- A delegation without the line skips this step, and the validation entry names the directory itself.

## Validation entry

Start `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] [--run-id [RUN_ID]]` against the round's final worktree contents as [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation) sets out. Include `--run-id` exactly when the admission step ran.

- The agent never chooses a class or a narrower command.
- A run that needs `DEV_VALIDATE_CMD` refuses an empty declaration before starting: a validation failure, never a fallback. Run nothing in its place.

## Verification scope

Run the delegation's required verification commands and follow the Visual QA rule in [dev-implement.md § 5](../workflows/dev-implement.md#5-validate). Before choosing local verification commands, read the entry's startup output.

- `validate-mode=ci local-checks=targeted-only` limits local verification to the fixture rows and must-fail controls the change needs, including delegated verification that fits that scope. Required CI runs the full lanes. The independent gates in this list still apply.
- When resuming this round's own run without its startup output, read `.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir [RUN_DIR]`. Use the same targeted scope if the record says `validate-mode=ci`. If the read fails or the mode is missing or unrecognized, record a validation failure with its cause and stop before choosing verification commands.
- Where the project sets `DEV_VALIDATE_SELECTION_CMD`, the entry previews selection and runs the selector scoped for an admitted CI run. The project owns what the selector runs, and a red scoped run is a failing `validate=` value like any other.
- A successful CI run records required CI as pending. The [accepted CI receipt route](../../orch/workflows/submit-pr.md#11-preflight) assigns downstream proof.

## Must-fail controls

Run the must-fail controls [code-quality § Tests](../../code-quality/SKILL.md#tests) requires, each scoped as [§ Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards) sets. A changed test file takes no run of its own: the runner's result covers it, locally or through required CI.

## Foreground route

A project whose own policy forbids orch's validation runner and requires its validation entry point in the foreground runs that entry point in the foreground as the policy sets out, in place of the runner. It takes these steps:

1. Record the run in `[WORKTREE_PATH]/tmp/validate-record-[ARTIFACT_KEY]-[DEV_ROUND_ID]`. A recovery attempt below records itself in `[WORKTREE_PATH]/tmp/validate-record-[ARTIFACT_KEY]-[DEV_ROUND_ID]-recovery` and preserves the original record.
2. Before the entry point starts, commit the final edits, where any exist, with the active workflow's commit instructions and metadata and no `[validate: ...]` line, since no verdict exists yet. Reuse that commit through completion and skip the workflow's later commit step.
3. Write the lines `validate-mode=full`, `head=` with `git -C [WORKTREE_PATH] rev-parse HEAD`, and `started-at=` with `date -u +%Y-%m-%dT%H:%M:%SZ`. Until a fix round's receipt is written, keep HEAD at the record's `head=` and the tree clean: a commit after the record leaves a fix round no receipt.
4. After it ends, add `ended-at=` the same way, `exit=` with its exit status, and `selection=` and `lanes=` from its `validate:` line, or `selection=unreported` where it printed none.

A run cut off before its exit status is known is `FAILING: [ENTRY_POINT]`. Preserve its unfinished record and log, omit both evidence flags, and explain the interruption in `--validate-note`. `orch-runtime dev-return --text write --help` gives each line's grammar.

## No-verdict

A command's exit 3 or an unavailable host check prints `validate=no-verdict`: neither a pass nor a failure.

- Read the run's record with `.agents/skills/orch/scripts/orch-runtime validate entry --record --run-dir [RUN_DIR]`.
- A record carrying `validate-mode=ci` takes no further run: required CI, the merge group for queue-only work, holds the full proof.
- A scoped record whose `validate-mode` is not `ci` takes no further start.
- A record that is not scoped and whose `validate-mode` is not `ci` takes at most one further runner start, `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --validate-mode ci --base [ROUND_BASE] [--run-id [RUN_ID]]`. `--run-id` carries the rerun's own id from the admission step exactly when the delegation carries an admission. The round's verdict is that run's.
- Run no suite list by hand in place of either.
- A final `no-verdict` is `--validate no-verdict` with its run's `run-dir=` as `--validate-run-dir` and a `--validate-note` naming the host cause or the command's exit 3, and the return reads `Validate: no-verdict: [CAUSE]`.
- Only a final record with `validate-mode=ci` leaves the proof to required CI. Any other final `no-verdict` is unproved: its `--validate-note` says so, and the round never presents it as covered by CI.

## Apple gate

`fleet-mac-run test` passes once for an item the Apple gate in `orch-runtime dev-return --text write --help` names, run through the orch job runner as [dev SKILL.md § Long-Running Validation](../SKILL.md#long-running-validation) sets out.

- The gate names an item when the base branch holds its workflow and an entry of the delegation's `Labels:` line, or a path the branch changes, matches its trigger.
- Fleet installs `fleet-mac-run` on the `PATH` of a lane in a repository it runs Apple builds for.
- A nonzero exit, or no `fleet-mac-run` on `PATH`, is `FAILING: mac run test`.
- A pass is the `--validate-note` line `mac run test: pass run=[RUN_ID]`, with the run id `fleet-mac-run` prints.
- An item the gate does not name runs nothing here.

## Selection and time readings

Read the run's selection and per-check time, where the project's output reports them, against [code-quality § Tests](../../code-quality/SKILL.md#tests): they are evidence for its selection and protection-against-cost rules, never a limit on the round, and change no verdict. Report under the completion summary's Discovered Work:

- a shared-input change that selected every check where the entry point could trace which checks reach it;
- a selected check outside this round's changes whose time goes to a real-clock wait or a real device effect its claim does not need.

## Run-live refusal

A start the validation entry refuses as `run-live`, with exit 2, ran nothing. It is no verdict on the change, never a validation failure, and does not end the round.

- Wait for the run its line names with `.agents/skills/orch/scripts/orch-runtime validate entry --wait --run-dir [RUN_DIR]`, polled as a cut-off start is.
- Or end it with `.agents/skills/orch/scripts/orch-runtime validate entry --stop --worktree [WORKTREE_PATH]` where it belongs to an abandoned round.
- If this round started the named run, continue with its verdict and recover its recorded mode as § Verification scope sets out.
- Otherwise start this round's run, under the same `--run-id` where the delegation carries an admission. The admission names the same run before its first start.

## Test-only validation ceiling

For a test-only PR whose validation runs longer than 30 minutes and fails, run the failed target alone once under load, as an investigation run under [dev SKILL.md § Validation](../SKILL.md#validation). Record both results in `--validate-note` with the prefix `Test-only validation ceiling:`. Report the result and do not extend validation.

## Recovery

A `validate=FAILING`, a failing required verification command, or another failing run in this gate permits one recovery sequence when every failing check has a named cause fixed within the delegated scope.

1. Stage the repaired final contents.
2. Read `orch-runtime validate policy --stage focused-proof` with `--base-checkout` naming the main checkout. Repeat each failed check once through its existing owner if the policy answers `run` or if the check is required and the configured rerun cannot be shown to cover it. Keep the CI verification scope above. If any repeated check fails or remains unread, stop.
3. Add no selector override, smaller base or replacement command.
4. When all those conditions hold and this round has not spent its correction/rerun allowance, run the unchanged configured validation once through its existing execution owner, preserving the real base and mode. The admission step's `"attempt": "next"` mints the rerun's own run id, and the rerun writes its own receipt under it, the failed receipt standing.
5. Record the causes, scoped repair, focused execution, both evidence locations and final verdict in the round notes, summary and `--validate-note`.

Existing fix-round calls into this section keep their delegated fix base and mode. This sequence grants no additional allowance after an earlier correction/rerun, validation refresh or recovery attempt.

An unknown or outside-scope cause, unproved repair/admission, refused start, another failed gate, stalled or lost run or unproved result stops this sequence.

- Keep the existing `run-live` wait ownership.
- Do not chain recovery into another start through the no-verdict route.
- The no-verdict and recorded context-handoff routes above still govern their original results; they grant no new allowance after recovery.
- Preserve the result and complete the tail.

### Stopped-round recovery

A stopped round whose failed receipt already exists uses the same qualification above and the original delegation, round id and baseline.

- Its rerun is the round's next admitted attempt, and `orch-runtime dev-return --text write` writes the attempt's receipt under the rerun's run id with the actual round commit and validation result, the failed receipt and run records kept.
- On the foreground route, commit any tracked repair after focused proof and admission, before the recovery entry point records HEAD, with the active workflow's commit instructions and metadata. Reuse that commit through completion and skip the workflow's later commit step, and name the recovery record with `--validate-record`.
- A foreground round whose `FAILING` receipt already stands under the round's no-run name is final.
- Evidence-only recovery can name the same round commit; create no empty commit.
- The attempt's receipt is terminal even when failing or unproved; this workflow controls the execution allowance.

## Where the records live

This is the one statement of where each round's Validation Routes rows live, for every reader:

- On a Linear item, a dev round's rows are in its evidence file, attached to the item the round served: the sub-issue for a bundled implement round, the workflow item for a fix round. `linear.sh attachments list [ITEM_ID]` lists the files and `linear.sh attachments fetch [URL] --output [PATH]` reads one. While the worktree holds it, the round's local `tmp/evidence-[ITEM_ID]-[DEV_ROUND_ID].md` is the same file.
- On a GitHub or ad-hoc item, a dev round's rows are in the orchestrator's session and merge comments, which orch's post-summary workflow § 1 fills from each round's local `tmp/evidence-[ITEM_ID]-[DEV_ROUND_ID].md`.
- A restack run's rows, which no dev round writes, are in those session and merge comments.

A validation-routing check reads the rows where this section places them. When it needs raw evidence, use the retained archive within its retention window or the operator's dated snapshot; an unavailable source stays unread.
