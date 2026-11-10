# Completion-artifact reference

Cross-verb routing behind the artifact rows in [../SKILL.md](../SKILL.md), and the answers those verbs give. Each verb's `--help` is its flag contract.

| Verb | Role |
|--------|------|
| `orch-runtime review-artifact check` | Validates a reviewer's on-disk JSON artifact — the sole reviewer completion condition; review-pr.md § 3.1 relays a rejection's `detail` on the single permitted re-delegation. With `--text` it prints the result object alone and exits 0 accepted, 1 rejected, 2 refused, the refusal a `review-artifact-check: KEY` line on stderr. |
| `orch-runtime dev-return write` | Writes a dev round's completion artifact atomically. Schema and refusals: [`../schemas/dev-return.md`](../schemas/dev-return.md). |
| `orch-runtime round stamp` | Orchestrator-side twin persisting a fix round's delegated item set at stamp time; immutable per round. Schema and refusals: [`../schemas/dev-round.md`](../schemas/dev-round.md). |
| `orch-runtime dev-return check` | Validates a dev round's artifact by round id and answers `accept`/`no-change`/`wait`/`retry` ([§ Receipt check answers](#receipt-check-answers)). Tracker corroboration and exact-commit acceptance binding stay in the orch acceptance tables. |
| `orch-runtime round recover` | Accepts a stalled round from its transcript, or mints its replacement ([§ Recovery answers](#recovery-answers)); [skill-rules.md](skill-rules.md) § Round Closure routes its line. |

## Validation command output

`DEV_VALIDATE_CMD` or `DEV_VALIDATE_RANGE_CMD` may print one line to report the checks it runs. `orch-runtime validate entry --record` reads it from the run log.

| Item | Contract |
|------|----------|
| Exit status | `DEV_VALIDATE_CMD` and `DEV_VALIDATE_RANGE_CMD` reserve exit 3 for unavailable host checks. Report the host cause in the log. Return 0 for pass and another nonzero status for a code defect. Wrap a test runner that exits with its failure count. `orch-runtime validate entry --help` states how an exit maps to the verdict; `dev-implement.md` § 5 owns the `no-verdict` route. A host result cannot supply the timeout-only reuse proof. |
| Line | `validate: lanes=<comma-separated names> selection=all\|subset\|battery` |
| Names | Non-empty ASCII names using letters, digits, `.`, `_` or `-`; no empty comma-separated element |
| `selection` | Eligible lanes follow the command's invocation mode and applicability rules, including change class and changed paths. `all` means every eligible lane; `subset` means the command chose fewer eligible lanes; `battery` means every lane the command has, none stood down for the change class or changed paths |
| Repeated lines | The last line starting with `validate:` owns the result |
| Missing or malformed last line | The start's previewed `selection=all` or `selection=subset`; otherwise `selection=unreported`. No `lanes` field; does not change the run verdict |
| `validate-mode` | `full`, `range`, `docs` or `ci`; names the invocation, not the lane selection |
| Finding line | A line starting with the prefix the project declares in `DEV_VALIDATE_FINDING_PREFIX`, such as `guard: ` for a guard printing `guard: suite=…`; a project that declares none has no finding-free run. A timeout or unavailable-host `no-verdict` run whose log holds none may supply its recorded tree through `--last-pass` to `restack-skip`, with `verdict=no-verdict`. This is not a passing verdict. Only a run the bound ended with no finding line answers a later start of the same command, class, docs verdict, base and finding prefix under no smaller bound, where that run read every path the start reads. That start runs nothing and records `no-verdict` naming `bound-run=` |

## Validation entry answers

`orch-runtime validate entry` prints each refusal as one `dev-validate-run: KEY cause=CAUSE` line on stderr. A refusal exits 2, but a refused `--stop` or restack check exits 1. These keys name what it could not do:

| Key | Meaning |
|-----|---------|
| `mode-conflict` | More than one action flag |
| `option-unused` | An option the action does not read, such as `--worktree` with `--record` |
| `required` | An option the action needs is missing |
| `invalid-run-id` | A `--run-id` outside the form an admission mints |
| `not-directory` | The worktree is not a directory |
| `invalid-mode` | `--validate-mode docs`, which the classifier alone resolves, or a word that is no mode |
| `reproduce-ci` | `--reproduce` with the `ci` mode |
| `mode-base-required` | A `range` or `ci` start with no `--base`, naming the mode |
| `mode-cause-missing` | A wider mode than the declaration's narrowest with no cause |
| `run-live` | Another run in the worktree still runs, naming its `run-dir` and `pid`; nothing ran |
| `over-bound` | The selector's expected time exceeds `DEV_VALIDATE_TIMEOUT_SECS`, naming both |
| `scratch` | The start's, or the restack check's, private scratch directory could not be made |
| `run-dir` | The run directory or the run index could not be written |
| `launch-failed` | The run's job could not start, or the launcher's record could not be written |
| `launch-unanswered` | The launcher gave no answer, naming the run directory |
| `runner` | A foreground start's runner record could not be written |
| `record` | `--record` over a run directory whose `start` record cannot be read |
| `scoped-base` | A scoped start could not read the branch's merge base |
| `orphaned-base` | A range start from an orphaned base could not read the branch's merge base |
| `rebase-map-unreadable` | A range start could not read the worktree's rebase map |
| `stop-unreadable` | A stop could not read a live child's process group |
| `proof-base-unresolved` | `--require-proof` could not resolve the base its proof is read against |

A start records two kinds of fallback on its `start` record, which `--record` reports. `class-fallback=` names why the change class fell back to the whole battery: `base-unresolved`, `worktree-unrecorded`, `classifier-absent`, `classifier-unreadable`, `docs-reader-unreadable`, `docs-reader-exit`, or `docs-reader-absent:` with the cause. `ci-fallback=` names why a `ci` request ran locally: `push-base`, `setting-empty`, `base-unresolved`, `class-uncovered`, `pr-not-open`, `rules-unread`, `context-unrequired` or `selection-unread`.

## Receipt check answers

`orch-runtime dev-return --text check` prints one result object: `verdict`, `ok`, `path`, `reason`, and the receipt's echoed validation fields. `ok` is true only for `reason: valid`, and the exit is 0 for `ok` true and 1 otherwise. `accept` is a valid receipt whose `validate` is `pass` or `no-verdict`; `no-change` is a valid receipt whose `validate` is `not-run` ([dev-return.md § No-change receipt](../schemas/dev-return.md#no-change-receipt)); `wait` is `reason: missing`; every other answer is `retry`.

| `reason` | Meaning |
|----------|---------|
| `valid` | Every gate holds; `warning: commit_unreachable` where the commit is not in HEAD's ancestry |
| `missing` | No receipt at the selected path |
| `invalid` | The receipt's identity or schema fails: another round or issue, or a field outside its shape |
| `mode_mismatch` | A `fix` receipt records another mode than its run's admitted entry, or `ci` where [dev-round.md](../schemas/dev-round.md) `pr_open` does not admit it |
| `commit_unverifiable` | The receipt's repository cannot be read as the worktree's own checkout |
| `commit_unresolvable` | The receipt's commit names no commit object |
| `ci_head_mismatch` | A `ci` receipt's commit is not the current HEAD |
| `head_moved` | A `not-run` receipt's commit is not the current HEAD: a no-change answer holds only at the HEAD the round left unmoved |
| `comparison_failed` | Git cannot compare the round's base against HEAD |
| `additions_unattributable` | A rebase moved the round's base off the branch and the rebase map proves no rewritten base |
| `unapproved_additions` | The round added protected paths its record does not authorize; `files` lists them |
| `incomplete` | The receipt's `items[]` does not match the expected set; `hint` names a count passed for item numbers |

Its refusals exit 2 with one `dev-artifact-check: KEY CAUSE` line on stderr and record nothing:

| Key | Meaning |
|-----|---------|
| `invalid-id` | The issue or round id is empty, carries `..`, or holds a character outside `A-Za-z0-9._-` |
| `not-directory` | The worktree cannot be read as a directory |
| `file-mode-required` | `--expect-items` without `--file` |
| `invalid-item-numbers` | An `--expect-items` entry is no number |
| `round-missing`, `round-json`, `round-mismatch`, `round-schema` | The round record is absent or no regular file, is no JSON, carries another round id, or fails [dev-round.md](../schemas/dev-round.md)'s schema |
| `expected-round-required` | A `fix` receipt checked in round mode without `--expect-items-from-round` |
| `receipt-ambiguous` | Several receipts of the round stand and no `validate` stage names one |
| `recovery-invalid` | A recovery companion does not bind its failed parent receipt |
| `artifact-unreadable` | The receipt or the worktree's `tmp/` cannot be read |
| `mode-unresolved` | The receipt records a mode word no reader knows |
| `git-failed`, `ancestry-unreadable` | A git read or an ancestry read gave no answer |

An answer the check could not record on the item carries `record_warning`; the verdict stands.

## Recovery answers

`orch-runtime round --text recover` prints one `round-recover: STATE ...` line and exits by its state:

| Line | Exit |
|------|------|
| `recovered artifact=PATH` | 0 |
| `redelegate round-id=ID from=ROUND reason=WHY` | 3 |
| `exhausted round-id=ID reason=WHY` | 1 |
| `round-live run-dir=DIR` | 4 |

A `redelegate` or `exhausted` line's `reason` is `no-transcript`, `no-report`, `unparsed`, `validate-unproven`, `commit-mismatch`, `mac-run-unproven` or `directive-unconfirmed`. A refusal exits 2 with one `round-recover: KEY CAUSE` line on stderr. Its own keys are below; a refusal from the writer or the check it runs reaches the caller under that verb's key.

| Key | Meaning |
|-----|---------|
| `invalid-id`, `not-directory` | As the check's |
| `transcript-unreadable` | The `--transcript` file cannot be read |
| `record-missing` | The item has no workflow state to mint the replacement in |
| `state-failed` | The item's recorded recovery cannot be read |
| `round-superseded` | Workflow state's `dev_round_id` names another round |
| `stop-failed` | A `--directive-unconfirmed` stop could not end one of the worktree's runs |
| `run-unreadable` | The round's runs, or one the reconcile reads, cannot be read |
| `round-missing`, `round-json`, `round-mismatch`, `round-schema` | As the check's, for a fix round's record |
| `git-failed` | Git could not read the worktree's HEAD or branch |
| `artifact-write` | The extracted report could not be written |

## Round-closure mechanics

- **The watchdog IS the check in blocking mode**: `orch-runtime dev-return --text check --wait <quiet_window> …` polls on-disk state and returns the moment a fresh artifact lands or at the deadline — return-message delivery is never load-bearing. Run A/B on its return if the round is still outstanding; re-arm only on entering a new escalation step. The reviewer side of the same invariant is stated once, in review-pr.md § 3.2, and never restated here.
- **A watchdog runs where its exit wakes the session.** Claude Code runs it as a background shell, whose exit is the event. Codex starts it through [waiter-launch.md](waiter-launch.md)'s job runner and holds its completion in the current turn ([codex-runtime.md § Delegated round wait](codex-runtime.md#delegated-round-wait) for a dev round, [§ Reviewer round wait](codex-runtime.md#reviewer-round-wait) for a reviewer). Pi runs it under `bg_task` and pairs it with the per-wake check; any other harness runs the check on each wake.
- **A watchdog that ends without a verdict leaves the round unwatched.** A verdict is exit 0 or 1; exit 2 is a keyed refusal, and any other status is an abort — judge on the status, since a keyed line may or may not have arrived with it. What to do about it is the re-arm rule's, not this file's: [skill-rules.md](skill-rules.md) § Round Closure item 2 states the exception that covers it.
- **The round token binds A to exactly this delegation's receipt.**
- **A path whose agent writes no dev-return artifact** (`ci-fix.md` pushes directly) always has A `verdict=wait`: accepted by its return message and the escalation ladder, never by a stale artifact.
- **Composite B never accepts on its own.** A return-message timeout, clean git status, and no modified files reflect worktree state only. The one positive signal that overrides a missing return is a valid receipt check for the current `dev_round_id`.

## Dev-vs-reviewer asymmetry (intentional — do not "align")

A reviewer invalid artifact after a return is `incomplete` and gets one re-delegation. Dev's verdict distinguishes a still-running round (`wait`, routed by the sentence ahead of the acceptance table in `dev-start.md` § 3 and `dev-fix.md` § 2, a stalled round to `orch-runtime round --text recover` first) from a present-but-failing receipt (`retry` — never accepted, never treated as absent) and from a round its item permits ending with no change (`no-change`), which `dev-start.md` § 3's row judges. Neither branch re-runs the work, and neither accepts without the round-scoped artifact.
