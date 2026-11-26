# Completion-artifact reference

Read when a workflow writes, checks or recovers a round's completion artifact, or reads a validation run's answer. Each verb's `--help` is its flag contract.

## Verbs

| Verb | Role |
|------|------|
| `orch-runtime review-artifact check` | Checks a reviewer's on-disk JSON artifact, the one reviewer completion condition |
| `orch-runtime dev-return write` | Writes a dev round's receipt atomically |
| `orch-runtime round stamp`, `round cut` | Writes a fix round's delegated item set once per round, before delegation |
| `orch-runtime dev-return check` | Checks a dev round's receipt by round id and answers a verdict |
| `orch-runtime round recover` | Accepts a stalled round from its transcript, or mints its replacement |

- `review-artifact check`:
  - [review-pr.md](../workflows/review-pr.md) § 3.1 relays a rejection's `detail` on the one permitted re-delegation.
  - With `--text` it prints the result object alone and exits 0 accepted, 1 rejected, 2 refused.
  - A refusal prints a `review-artifact: KEY` line on stderr.
- `dev-return write`: schema and refusals are [dev-return.md](../schemas/dev-return.md).
- `round stamp`, `round cut`: `cut` declares a cut round. Schema and refusals are [dev-round.md](../schemas/dev-round.md).
- `dev-return check`: its answers are [§ Receipt check answers](#receipt-check-answers). The delegating workflow's acceptance table keeps tracker corroboration and the exact-commit binding.
- `round recover`: its answers are [§ Recovery answers](#recovery-answers). [skill-rules.md § Stalled round](skill-rules.md#stalled-round) routes its line.

## Validation command output

`DEV_VALIDATE_CMD` or `DEV_VALIDATE_RANGE_CMD` may print one line naming the checks it ran. `orch-runtime validate entry --record` reads that line from the run's log; its `--help` states which line wins and what a missing one records.

- **Exit status.**
  1. Exit 3 means host checks were unavailable; name the host cause in the log.
  2. Exit 0 for a pass and another nonzero status for a code defect.
  3. Wrap a test runner that exits with its failure count.
  4. `orch-runtime validate entry --help` maps exits to verdicts; [validation.md § No-verdict](../../dev/references/validation.md#no-verdict) owns the `no-verdict` route.
- **Line.** `validate: lanes=<comma-separated names> selection=all|subset|battery`
- **Names.** Non-empty ASCII names of letters, digits, `.`, `_` or `-`; no empty element.
- **`selection`.**
  - The command's invocation mode and applicability rules, change class and changed paths included, decide which lanes are eligible.
  - `all` is every eligible lane. `subset` is fewer.
  - `battery` is every lane the command has, none stood down for the change class or paths.
- **Finding line.**
  - A finding line starts with the project's `DEV_VALIDATE_FINDING_PREFIX`, such as `guard: ` for `guard: suite=…`.
  - A project that declares none has no finding-free run.
  - A `no-verdict` run whose log holds no finding line counts as the last pass `orch-runtime validate entry --last-pass` reports, marked `verdict=no-verdict`. That is not a passing verdict.

## Validation entry answers

`orch-runtime validate entry` prints each refusal on stderr as its text, then a last `validate: KEY field=value ...` line, which a reader keys on. A cause of more than one word appears only in the text. A refusal exits 2; a refused `--stop` or restack check exits 1.

`--record` reports two fallbacks from the `start` record:

- `class-fallback=` names why the change class fell back to the whole battery: `base-unresolved`, `worktree-unrecorded`, `classifier-absent`, `classifier-unreadable`, `docs-reader-unreadable`, `docs-reader-exit`, or `docs-reader-absent:` with the cause.
- `ci-fallback=` names why a `ci` request ran locally: `push-base`, `setting-empty`, `base-unresolved`, `class-uncovered`, `pr-not-open`, `rules-unread`, `context-unrequired` or `selection-unread`.

## Receipt check answers

`orch-runtime dev-return --text check` prints one result object: `verdict`, `ok`, `path`, `reason`, `warning`, `hint`, `files`, and the receipt's echoed fields ([dev-return.md § Fields](../schemas/dev-return.md#fields)). `ok` is true only for `reason: valid`. The check exits 0 when `ok` is true and 1 otherwise.

| Verdict | When |
|---------|------|
| `accept` | A valid receipt whose `validate` is `pass` or `no-verdict` |
| `accept-excused` | A valid `FAILING` receipt whose every failing check the round's exception excuses |
| `no-change` | A valid receipt whose `validate` is `not-run` ([dev-return.md § No-change receipt](../schemas/dev-return.md#no-change-receipt)) |
| `hand-over` | A valid receipt whose `validate` is `handed-over` ([dev-return.md § Hand-over receipt](../schemas/dev-return.md#hand-over-receipt)) |
| `wait` | `reason: missing` |
| `retry` | Every other answer |

- `reason` names the gate a `retry` failed; the delegating workflow's acceptance table routes each reason it acts on.
- `valid` may carry `warning: commit_unreachable` where the commit is not in HEAD's ancestry.
- For every `reason` but `missing` and `invalid`, a round-mode check sets the round entry's kind and records the run's cost in `validate_rounds`. Where the check cannot record the answer on the item, it adds `record_warning`; the verdict stands.
- A refusal records nothing and exits 2 with one `dev-return: KEY CAUSE` line on stderr.

## Recovery answers

`orch-runtime round --text recover` prints one `round: STATE …` line, which [skill-rules.md § Stalled round](skill-rules.md#stalled-round) routes; a `redelegate` or `exhausted` line names its `reason`. A replacement round keeps the group and the exception the replaced round began with. A refusal exits 2 with one `round: KEY CAUSE` line on stderr; a refusal from the writer or the check it runs reaches the caller under that key.

## Round closure mechanics

- **The watchdog is the check in blocking mode.**
  - `orch-runtime dev-return --text check --wait <quiet_window> …` polls the disk. It returns when a receipt lands, or at the deadline.
  - Delivery of the return message is never load-bearing.
  - If the round is still outstanding when it returns, run A and B.
  - [review-cycle.md § Reviewer wait](review-cycle.md#reviewer-wait) states the reviewer side.
- **A watchdog runs where its end wakes the session.**
  - A lane launches it as [skill-rules.md § Round Closure](skill-rules.md#round-closure) step 5 states, then ends its turn; the job's end arrives as the lane's mail.
  - A session that is no lane keeps its own wait.
    - Claude Code runs the watchdog as a background shell, whose exit is the event.
    - Codex holds it as [codex-runtime.md § Delegated round wait](codex-runtime.md#delegated-round-wait) states for a dev round and [§ Reviewer round wait](codex-runtime.md#reviewer-round-wait) for a reviewer.
    - Pi runs it under `bg_task`, paired with the per-wake check.
    - Any other harness runs the check on each wake.
- **A watchdog that ends without a verdict leaves the round unwatched.**
  - A verdict exits 0 or 1. Exit 2 is a keyed refusal; any other status is an abort.
  - Judge on the status, since the keyed line may not arrive with it.
  - The re-arm rule is [skill-rules.md § Round Closure](skill-rules.md#round-closure) item 5.
