# Multi-lane review

How `review` collects ordered opinions, merges their findings, places their artifacts, and classifies their failures.

## Lane resolution

The roster `SECOND_OPINION_MODELS` is walked in order, and a target is taken when it passes every check below:

| Check | Skipped when |
|---|---|
| Name shape | Not `^[A-Za-z][A-Za-z0-9_-]*$` |
| One configuration | Its `SECOND_OPINION_<NAME>_*` namespace was already considered (`my-model` and `my_model` are one configuration) |
| Cross-model | Its declared identity equals the session's |
| Distinct model | Its identity is already covered by a successful opinion |
| Available | Its configured command's program word does not resolve |
| Room | Its room check is unavailable, refused, or printed a line that is no `NAME=value` assignment |

- An entry with no room check passes the Room check.
- Every skip is one line on stderr naming the target and the cause.
- `second-opinion --help` gives how a target's and the session's identities resolve, and each room check's command.

Commands run one at a time.

- Review mode stops after `SECOND_OPINION_COUNT` successful opinions (default 1) or roster exhaustion.
- Every other mode stops after one opinion or exhaustion.
- A failed attempt does not reserve its model.

On the roster `pi-copilot claude pi-copilot-gpt codex`, two opinions from a session with no model are `pi-copilot` and `pi-copilot-gpt`: `claude` is skipped as `pi-copilot`'s model again, and `codex` is reached only when a Copilot entry is skipped or fails.

Coverage follows the `qa_metadata.coverage` definition under [Union merge](#union-merge). A requested count of two or more uses the union collector. `--target` and `SECOND_OPINION_TARGET` replace the walk with the one named target, which passes the same checks and never falls through.

Adding a lane is a settings entry, not new code:

- Add its name to `SECOND_OPINION_MODELS`.
- Define `SECOND_OPINION_<NAME>_CMD`, the name uppercased and hyphens as underscores.
- Define `SECOND_OPINION_<NAME>_MODEL` when the CLI fronts a model other than its own name, or is named for a harness that fronts a selectable model.

## Union merge

Findings are deduplicated by normalized location, plus the finding's occurrence index among same-location findings **within its own lane**.

- Normalizing a location lowercases it, removes backticks and collapses whitespace runs.
- One lane reporting two distinct findings at a location keeps both.
- The same finding reported by two lanes merges.
- A finding with an empty location never deduplicates.
- Duplicates collapse to the first of their group and carry every contributing lane in `sources`.
- A suggestion is dropped only when a blocker holds its exact key: for the same slot the stricter class wins.

| Field | Meaning |
|---|---|
| `agent` | `external-union(<lane>+<lane>)` over the lanes that answered |
| `verdict` | `action_required` when the merged blockers are non-empty, else `pass` |
| `summary` | Each lane's own summary, lane-labelled |
| `qa_metadata.union` | Always `true` for a union artifact |
| `qa_metadata.coverage` | `full` when the requested number of valid opinions stands; `degraded` for a shortfall |
| `qa_metadata.attempts` | Each CLI invocation in execution order, format retries included |
| `qa_metadata.requested_count` | Requested opinions |
| `qa_metadata.selected_count` | Attempted eligible targets |
| `qa_metadata.lanes` | One entry per lane |
| `qa_metadata.dedupe` | Findings in and out, per class |
| `qa_metadata.reviewed_head` | The head commit every lane reviewed |

- Each attempt carries `name`, `cause` and `seconds`. A Claude attempt adds `account`, the configuration directory name, when known.
- Failure and rejected-response records carry `attempts` too.
- `lanes` lists the answering lanes first, with their agent, verdict and finding counts.
- It then lists the failed lanes, with `status: "failed"`, or `"killed"` for a lane that died to a signal, and their exit code.

## Artifacts

- With `--output`, the union is written there.
  - Each lane's own artifact is kept beside it as `<output>.<target>.json`.
  - That lane's sidecar family (`.raw.txt`, `.retry.txt`, `.failed.json`, `.noreview.json`, `.incomplete.json`) sits next to it.
- Without `--output`, the union goes to stdout.
  - Each lane's artifact is a per-run file in `SECOND_OPINION_ARTIFACT_DIR` (default `tmp/second-opinion` under `--cwd`), with the same sidecar family beside it.
  - The parent removes both at exit.

## Failure classes

One failed lane does not fail the run.

- It is recorded in `qa_metadata.lanes`, and the collector continues down the roster.
- Coverage follows [Union merge](#union-merge).
- The run exits 0 with surviving findings when any valid opinion stands.

A lane's artifact is usable only if it holds exactly one JSON object shaped the way the merge consumes it. Each rejection names itself on stderr. Rejecting an artifact keeps that lane's failure local: exit 4.

The line between the two failure classes is whether the lane produced any bytes at all:

- An artifact with content the merge cannot consume, including one holding only whitespace, is the lane answering unusably (4).
- An absent or zero-byte artifact, or a lane that exited 0 leaving nothing, is the lane never answering (5).

A lane that died to a signal is a KILL, recorded as `status: "killed"` and reported with the signal's name. Something outside the run took the reviewer away; it did not refuse.

- A lane child reaped with a status of 128+N, where N is a signal the shell can name, died to a signal.
- So did a lane whose CLI the child classified as killed (exit 6).

When **every** lane fails there is no artifact, and the run takes the aggregate of those classes:

1. 4 when at least one lane answered unusably: its own exit 4, an artifact the merge could not consume, or a response-defect exit 1.
2. Else 6 when any lane was killed.
3. Else 5 when no lane ever answered.
