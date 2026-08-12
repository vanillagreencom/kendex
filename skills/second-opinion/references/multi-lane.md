# Multi-lane review

How `review` fans out across lanes, merges their findings, places their
artifacts, and classifies their failures. The caller-visible contract is in
SKILL.md; this file is the mechanism behind it.

## Lane resolution

`SECOND_OPINION_REVIEW_TARGETS` (default `codex claude`, space- or
comma-separated) lists the lanes. A target joins the run when it has a
configured command whose first word resolves — the first word is what gets
executed, and an override may point it away from the target's own name.

Names must match `^[A-Za-z][A-Za-z0-9_-]*$` and each available target joins at
most once. An invalid or repeated name is skipped loudly on stderr: an
arbitrary token would otherwise reach indirect variable expansion and per-lane
file paths, and a duplicate would launch concurrent children racing on one
lane's artifact and stderr paths.

Two or more resolved lanes make the run multi-lane. One resolved lane runs as
a single-lane review; none falls through to the single-lane resolver so the
error keeps the familiar "CLI not found" shape. `--target` and
`SECOND_OPINION_TARGET` force a single lane and disable the fan-out.

Adding a lane is a settings entry, not new code: add its name to
`SECOND_OPINION_REVIEW_TARGETS` and define `SECOND_OPINION_<NAME>_CMD` (name
uppercased, hyphens as underscores).

## Scope

The scope is derived once, up front, before any lane spawns: an empty diff
exits 3 without spawning anything, and every lane receives the same range
resolved to concrete commits. A commit landing mid-review cannot shift what a
lane sees, and the endpoint is stamped as `qa_metadata.reviewed_head`.

Each lane is a recursive single-target invocation of the script, so every lane
keeps the full single-lane contract: scope embedding, one-shot retry, the
no-review and incomplete gates, and its own sidecar family.

## Union merge

Findings are deduplicated by normalized location — lowercased, backticks
removed, whitespace runs collapsed — plus the finding's occurrence index among
same-location findings **within its own lane**. One lane reporting two distinct
findings at a location keeps both; the same finding reported by two lanes
merges. A finding with an empty location never deduplicates.

Duplicates collapse to the first of their group and carry every contributing
lane in `sources`. A suggestion is dropped only when a blocker holds its exact
key: for the same slot the stricter class wins.

| Field | Meaning |
|---|---|
| `agent` | `external-union(<lane>+<lane>)` over the lanes that answered |
| `verdict` | `action_required` when the merged blockers are non-empty, else `pass` |
| `summary` | Each lane's own summary, lane-labelled |
| `qa_metadata.union` | Always `true` for a union artifact |
| `qa_metadata.coverage` | `full` when every lane answered, `degraded` otherwise |
| `qa_metadata.lanes` | One entry per lane: the answering lanes with their agent, verdict and finding counts, then the failed ones with `status: "failed"` and their exit code |
| `qa_metadata.dedupe` | Findings in and out, per class |
| `qa_metadata.reviewed_head` | The scope-derivation pin |

## Artifacts

With `--output`, the union is written there and each lane's own artifact is
kept beside it as `<output>.<target>.json`, with that lane's sidecar family
(`.raw.txt`, `.retry.txt`, `.noreview.json`, `.failed.json`) next to it.
Without `--output` the union goes to stdout and the per-lane artifacts are
temp files the parent removes.

Stale files at those paths are removed before lanes spawn — the union artifact
and every lane's own family. A previous run's union would otherwise read as a
fresh pass to a caller that continued past an advisory failure, and a previous
run's lane artifact is misleading whether or not the current run overwrites it.

Lane children run under a restrictive umask, so every file they write — lane
artifacts and sidecars alike — is owner-only. The union artifact is written by
the parent after the umask is restored, so it follows the caller's umask.

## Scratch and durability

The run creates exactly one directory under `TMPDIR` and it holds nothing but
the per-lane stderr captures. Losing it — an agent CLI, a sandbox, or a tmp
reaper clearing scratch mid-run — costs the log replay, which is reported as
such, and never a verdict.

Each lane's review is held in memory from the moment that lane is reaped, so
the merge never reads it back from disk. Where it sits until then depends on
the mode:

| Mode | Lane review lives in | Effect of a temp-space actor |
|---|---|---|
| `--output` | The durable sibling beside the union | None — it is not in temp space |
| stdout | An ordinary temp file | That lane is lost, but loudly: coverage `degraded`, the lane recorded at exit 5, the loss named on stderr |

## Failure classes

One failed lane does not fail the run: a quota-capped lane would otherwise
block every review. It is recorded in `qa_metadata.lanes`, coverage becomes
`degraded`, and the run still exits 0 with the surviving lanes' findings.

A lane's artifact is usable only if it holds exactly one JSON object shaped the
way the merge consumes it. Each rejection names itself on stderr:

| Rejected shape | Why the merge needs it |
|---|---|
| Not exactly one JSON value | Several values would smuggle extra lanes into the merge; none is nothing to merge |
| Top level not an object | The lane's review is the object being wrapped |
| `blockers` / `suggestions` not an array of objects | Each finding gets `{source: <lane>}` added |
| A finding's `location` not a string | Locations are lowercased for the dedupe key |
| `questions` not an array | Questions are iterated and uniqued |
| `summary` not a string | Summaries are concatenated into the union summary |

Rejecting an artifact keeps that lane's failure local — exit 4, coverage
degraded — instead of aborting the merge and losing every other lane's review.

The line between the two failure classes is whether the lane produced any bytes
at all. An artifact with content the merge cannot consume, including one
holding only whitespace, is the lane answering unusably (4). An absent or
zero-byte artifact, or a lane that exited 0 leaving nothing, is the lane never
answering (5).

When **every** lane fails there is no artifact and the run takes the aggregate
of those classes: 4 when at least one lane answered unusably — its own exit 4,
an artifact the merge could not consume, or a response-defect exit 1 — and 5
when no lane ever answered.
