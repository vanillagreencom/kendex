# Completion-artifact reference

Read when a workflow writes, checks or recovers a round's completion artifact, or reads a validation run's answer: the answers of the artifact and validation verbs, and the round-closure rules they serve. Each verb's `--help` is its flag contract.

## Verbs

| Verb | Role |
|------|------|
| `orch-runtime review-artifact check` | Checks a reviewer's on-disk JSON artifact, the one reviewer completion condition; [review-pr.md](../workflows/review-pr.md) § 3.1 relays a rejection's `detail` on the one permitted re-delegation. With `--text` it prints the result object alone and exits 0 accepted, 1 rejected, 2 refused, the refusal a `review-artifact: KEY` line on stderr. |
| `orch-runtime dev-return write` | Writes a dev round's receipt atomically. Schema and refusals: [dev-return.md](../schemas/dev-return.md). |
| `orch-runtime round stamp`, `round cut` | Writes a fix round's delegated item set before delegation, once per round; `cut` declares a cut round. Schema and refusals: [dev-round.md](../schemas/dev-round.md). |
| `orch-runtime dev-return check` | Checks a dev round's receipt by round id and answers a verdict ([§ Receipt check answers](#receipt-check-answers)). Tracker corroboration and the exact-commit binding stay in the delegating workflow's acceptance table. |
| `orch-runtime round recover` | Accepts a stalled round from its transcript, or mints its replacement ([§ Recovery answers](#recovery-answers)); [skill-rules.md § Stalled round](skill-rules.md#stalled-round) routes its line. |

## Validation command output

`DEV_VALIDATE_CMD` or `DEV_VALIDATE_RANGE_CMD` may print one line to report the checks it ran. `orch-runtime validate entry --record` reads it from the run's log.

| Item | Contract |
|------|----------|
| Exit status | Exit 3 is reserved for unavailable host checks: report the host cause in the log. Return 0 for a pass and another nonzero status for a code defect; wrap a test runner that exits with its failure count. `orch-runtime validate entry --help` states how an exit maps to the verdict; [dev-implement.md § 5](../../dev/workflows/dev-implement.md#5-validate) owns the `no-verdict` route. |
| Line | `validate: lanes=<comma-separated names> selection=all\|subset\|battery` |
| Names | Non-empty ASCII names of letters, digits, `.`, `_` or `-`; no empty comma-separated element |
| `selection` | Eligible lanes follow the command's invocation mode and applicability rules, change class and changed paths included. `all` is every eligible lane; `subset` is fewer eligible lanes than that; `battery` is every lane the command has, none stood down for the change class or the changed paths |
| Repeated lines | The last line starting `validate: lanes=` owns the result |
| Missing or malformed last line | The start's previewed `selection=all` or `selection=subset`, else `selection=unreported`. No `lanes` field. The run's verdict is unchanged |
| `validate-mode` | `full`, `range`, `docs` or `ci`; it names the invocation, not the lane selection |
| Finding line | A line starting with the prefix the project declares in `DEV_VALIDATE_FINDING_PREFIX`, such as `guard: ` for a guard printing `guard: suite=…`. A project that declares none has no finding-free run. A `no-verdict` run whose log holds no finding line counts as the last pass `orch-runtime validate entry --last-pass` reports, marked `verdict=no-verdict`; that is not a passing verdict |

## Validation entry answers

`orch-runtime validate entry` prints each refusal as one `validate: KEY cause=CAUSE` line on stderr. A refusal exits 2; a refused `--stop` or restack check exits 1. The keys name what it could not do:

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
| `mode-cause-missing` | A wider mode than the declaration's narrowest, with no cause |
| `setting-unread`, `setting-invalid` | A delivery or order setting the load could not read; an `ORCH_VALIDATE_MEMORY_MAX` that is no size or is under its 1G floor |
| `memory-short` | The run's memory need exceeds the room this host can give it, naming both |
| `run-live` | Another run in the worktree still runs, naming its `run-dir` and `pid`; nothing ran |
| `tmp`, `scratch` | The worktree's `tmp/`, or the start's or restack check's private scratch directory, could not be made |
| `run-dir`, `run-index` | The run directory, or the run index, could not be written |
| `group-leader-missing`, `missing-command` | A foreground start without the github skill's group-leader prefix, or without `perl` on `PATH` |
| `exe`, `launch-failed` | The runtime could not name its own binary, or the run's job could not start |
| `launch-unanswered` | The launcher gave no answer, naming the run directory |
| `owner`, `runner` | A foreground start with no owner identity, or whose runner record could not be written |
| `stdout` | The started line could not be printed |
| `record`, `no-run` | `--record` over a run directory whose `start` record cannot be read; a run directory whose `start` names no worktree |
| `scoped-base` | A scoped start could not read the branch's merge base |
| `stop-unreadable` | A stop could not read a run's stop mark or a live child's process group |

A start records two kinds of fallback on its `start` record, which `--record` reports:

- `class-fallback=` names why the change class fell back to the whole battery: `base-unresolved`, `worktree-unrecorded`, `classifier-absent`, `classifier-unreadable`, `docs-reader-unreadable`, `docs-reader-exit`, or `docs-reader-absent:` with the cause.
- `ci-fallback=` names why a `ci` request ran locally: `push-base`, `setting-empty`, `base-unresolved`, `class-uncovered`, `pr-not-open`, `rules-unread`, `context-unrequired` or `selection-unread`.

## Receipt check answers

`orch-runtime dev-return --text check` prints one result object: `verdict`, `ok`, `path`, `reason`, `warning`, `hint`, `files`, and the receipt's echoed fields ([dev-return.md § Fields](../schemas/dev-return.md#fields)). `ok` is true only for `reason: valid`; the exit is 0 for `ok` true and 1 otherwise. The verdict:

| Verdict | When |
|---------|------|
| `accept` | A valid receipt whose `validate` is `pass` or `no-verdict` |
| `accept-excused` | A valid `FAILING` receipt whose every failing check the round's exception excuses |
| `no-change` | A valid receipt whose `validate` is `not-run` ([dev-return.md § No-change receipt](../schemas/dev-return.md#no-change-receipt)) |
| `hand-over` | A valid receipt whose `validate` is `handed-over` ([dev-return.md § Hand-over receipt](../schemas/dev-return.md#hand-over-receipt)) |
| `wait` | `reason: missing` |
| `retry` | Every other answer |

| `reason` | Meaning |
|----------|---------|
| `valid` | Every gate holds; `warning: commit_unreachable` where the commit is not in HEAD's ancestry |
| `missing` | No receipt at the selected path |
| `invalid` | The receipt's identity or schema fails: another round or issue, a field outside its shape, or an `exception` that is not one |
| `exception_unbegun` | The receipt cites an exception the round did not begin with |
| `mode_mismatch` | A `fix` receipt records another mode than its run's admitted entry, or `ci` where the round's `pr_open` and `pr-order` do not admit it ([dev-return.md § Fix-round run binding](../schemas/dev-return.md#fix-round-run-binding)) |
| `commit_unverifiable` | The receipt's repository cannot be read as the worktree's own checkout |
| `commit_unresolvable` | The receipt's commit names no commit object |
| `ci_head_mismatch` | A `ci` receipt's commit is not the current HEAD |
| `head_moved` | A `not-run` receipt's commit is not the current HEAD: a no-change answer holds only at the HEAD the round left unmoved |
| `comparison_failed` | Git cannot compare the round's base with HEAD |
| `additions_unattributable` | A rebase moved the round's base off the branch, and the rebase map proves no rewritten base |
| `unapproved_additions` | The round added protected paths its record does not authorize; `files` lists them |
| `incomplete` | The receipt's `items[]` does not match the expected set; `hint` names a count passed for item numbers |

For every `reason` but `missing` and `invalid`, a round-mode check sets the round entry's kind and records the run's cost in `validate_rounds`. An answer the check could not record on the item carries `record_warning`; the verdict stands.

Its refusals exit 2 with one `dev-return: KEY CAUSE` line on stderr and record nothing:

| Key | Meaning |
|-----|---------|
| `invalid-id` | The issue or round id is empty, holds `..`, or holds a character outside `A-Za-z0-9._-` |
| `not-directory` | The worktree cannot be read as a directory |
| `file-mode-required` | `--expect-items` without `--file` |
| `invalid-item-numbers` | An `--expect-items` entry is not a number |
| `round-missing`, `round-json`, `round-mismatch`, `round-schema` | The round record is absent or not a regular file, is not JSON, carries another round id, or fails [dev-round.md](../schemas/dev-round.md)'s schema |
| `expected-round-required` | A `fix` receipt checked in round mode without `--expect-items-from-round` |
| `receipt-ambiguous` | Several receipts of the round stand and no `validate` stage names one |
| `artifact-unreadable` | The receipt or the worktree's `tmp/` cannot be read |
| `mode-unresolved` | The receipt records a mode word no reader knows |
| `git-failed`, `ancestry-unreadable` | A git read or an ancestry read gave no answer |

## Recovery answers

`orch-runtime round --text recover` prints one `round: STATE …` line and exits by its state:

| Line | Exit |
|------|------|
| `round: recovered artifact=PATH` | 0 |
| `round: redelegate round-id=ID from=ROUND reason=WHY` | 3 |
| `round: exhausted round-id=ID reason=WHY` | 1 |
| `round: round-live run-dir=DIR` | 4 |

A `redelegate` or `exhausted` line's `reason` is `no-transcript`, `no-report`, `unparsed`, `validate-unproven`, `commit-mismatch`, `mac-run-unproven` or `directive-unconfirmed`. A replacement round keeps the group and the exception the replaced round began with. A refusal exits 2 with one `round: KEY CAUSE` line on stderr. Its own keys are below; a refusal from the writer or the check it runs reaches the caller under that key.

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
| `artifact-write`, `artifact-cleanup` | The extracted report could not be written, or its scratch file removed |

## Round closure mechanics

- **The watchdog is the check in blocking mode.** `orch-runtime dev-return --text check --wait <quiet_window> …` polls the disk and returns the moment a receipt lands, or at the deadline; delivery of the return message is never load-bearing. Run A and B on its return if the round is still outstanding, and re-arm only on entering a new escalation step. The reviewer side of the same rule is stated once, in [review-pr.md](../workflows/review-pr.md) § 3.2.
- **A watchdog runs where its end wakes the session.** A lane launches it through [Waiter launch](waiter-launch.md#launch) with `--owner [ISSUE_ID]` and ends its turn; the job's end arrives as the lane's mail. A session that is no lane keeps its own wait: Claude Code runs the watchdog as a background shell, whose exit is the event; Codex holds it as [codex-runtime.md § Delegated round wait](codex-runtime.md#delegated-round-wait) states for a dev round and [§ Reviewer round wait](codex-runtime.md#reviewer-round-wait) for a reviewer; Pi runs it under `bg_task`, paired with the per-wake check; any other harness runs the check on each wake.
- **A watchdog that ends without a verdict leaves the round unwatched.** A verdict exits 0 or 1; exit 2 is a keyed refusal, and any other status is an abort. Judge on the status, since a keyed line may or may not have arrived with it. The re-arm rule is [skill-rules.md § Round Closure](skill-rules.md#round-closure) item 5.
- **The round token binds A to exactly this delegation's receipt.**
- **A route whose agent writes no receipt** (`ci-fix.md`, which pushes directly) always has A `wait`: it accepts on the return message and the escalation ladder, never on a stale receipt.
- **Composite B never accepts on its own.** A return-message timeout, a clean git status and no modified files describe the worktree alone. The one positive signal that overrides a missing return is a valid receipt check for the current `dev_round_id`.

## Dev-vs-reviewer asymmetry

The asymmetry is intended; do not align the two sides. A reviewer's invalid artifact after a return is `incomplete` and gets one re-delegation. A dev round's verdict tells apart a round still running (`wait`, routed by the stalled-round rule ahead of the acceptance table in [dev-start.md § 3](../workflows/dev-start.md#3-accept-the-round) and [dev-fix.md § 2](../workflows/dev-fix.md#2-delegate), a stalled round going to `orch-runtime round --text recover` first), a present but failing receipt (`retry`: never accepted, never treated as absent), a round its item permits ending with no change (`no-change`, which dev-start § 3's row judges), a group handing its work to the next (`hand-over`), and a failure the round's exception excuses (`accept-excused`). Neither side re-runs the work, and neither accepts without the round-scoped artifact.
