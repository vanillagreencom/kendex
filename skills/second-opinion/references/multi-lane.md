# Multi-lane review

How `review` fans out across lanes, merges their findings, places their
artifacts, and classifies their failures.

## Lane resolution

The roster
`SECOND_OPINION_MODELS` (default `claude codex`, space- or comma-separated) is
walked in order and a target is taken when all of these hold:

| Check | Skipped when |
|---|---|
| Name shape | Not `^[A-Za-z][A-Za-z0-9_-]*$` |
| One configuration | Its `SECOND_OPINION_<NAME>_*` namespace was already considered (`my-model` and `my_model` are one configuration) |
| Cross-model | Its declared identity (`SECOND_OPINION_<NAME>_MODEL`, default the name, model ids normalized) equals the session's (the detected harness's model where there is one, else `SECOND_OPINION_CURRENT_MODEL`; a declaration contradicting a detected harness is refused). A session with no identity, or one whose `SECOND_OPINION_CURRENT_MODEL` the roster does not spell, refuses every target; `none` declares no session model. A *detected* identity the roster does not name excludes nothing |
| Distinct model | Its identity is already covered by a taken lane |
| Available | Its configured command's first word does not resolve |

Every skip is one line on stderr naming the target and the cause. Review mode
stops after `SECOND_OPINION_COUNT` lanes (default 1); every other mode after
one. Fewer lanes than requested is stated on stderr and stamped into the
artifact — `qa_metadata.requested_count`, `qa_metadata.selected_count`, and
`coverage: "degraded"`. Two or more lanes make the run multi-lane; one runs
as a single-lane review; none is a refusal — exit 1, a JSON error on stderr
listing every candidate with its reason, no artifact, no CLI invoked.
`--target` and `SECOND_OPINION_TARGET` replace the walk with the one named
target, which passes the same checks: forcing the session's own model is
refused.

Adding a lane is a settings entry, not new code: add its name to
`SECOND_OPINION_MODELS`, define `SECOND_OPINION_<NAME>_CMD` (name uppercased,
hyphens as underscores), and — when the CLI fronts a model other than its own
name — `SECOND_OPINION_<NAME>_MODEL`.

## Scope

The scope is derived once, up front, before any lane spawns: an empty diff
exits 3 without spawning anything, and every lane receives the same range
resolved to concrete commits. The endpoint is stamped as
`qa_metadata.reviewed_head`.

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
| `qa_metadata.coverage` | `full` only when every selected lane answered AND as many lanes were selected as `SECOND_OPINION_COUNT` requested; `degraded` for either shortfall (see `requested_count` / `selected_count`) |
| `qa_metadata.lanes` | One entry per lane: the answering lanes with their agent, verdict and finding counts, then the failed ones with `status: "failed"` — or `"killed"` for a lane that died to a signal — and their exit code |
| `qa_metadata.dedupe` | Findings in and out, per class |
| `qa_metadata.reviewed_head` | The scope-derivation pin |

## Artifacts

With `--output`, the union is written there and each lane's own artifact is
kept beside it as `<output>.<target>.json`, with that lane's sidecar family
(`.raw.txt`, `.retry.txt`, `.failed.json`, `.noreview.json`, `.incomplete.json`)
next to it.
Without `--output` the union goes to stdout and each lane's artifact is a
per-run file in `SECOND_OPINION_ARTIFACT_DIR` (default `tmp/second-opinion`
under `--cwd`), with the same sidecar family beside it; the parent removes both
at exit.

Stale files under a caller's `--output` are removed before lanes spawn — the
union artifact, and each lane's artifact and those exact sidecar suffixes. The
suffixes are enumerated, never globbed.

A lane artifact and the sidecars beside it are written owner-only by the child
that writes them, whatever the caller's umask, and each is created rather than
written through whatever is found at the name. Nothing else the lane creates
inherits that restriction. The union artifact follows the caller's umask.

## Scratch and durability

The run creates exactly one directory under `TMPDIR` and it holds nothing but
the per-lane stderr captures. Losing it mid-run costs the log replay, which is
reported as such, and never a verdict.

Each lane's review is held in memory from the moment that lane is reaped.
Where it sits until then depends on the mode:

| Mode | Lane review lives in | Effect of a temp-space actor |
|---|---|---|
| `--output` | The durable sibling beside the union | None — it is not in temp space |
| stdout | A per-run file in the artifact home | None — it is not in temp space |

The one exception is a home that cannot be created or vetted: the lane falls
back to a temp file, with the cause on stderr, and losing it degrades
coverage, records that lane at exit 5 and names the loss.

## Failure classes

One failed lane does not fail the run. It is recorded in `qa_metadata.lanes`,
coverage becomes `degraded`, and the run still exits 0 with the surviving
lanes' findings.

A lane's artifact is usable only if it holds exactly one JSON object shaped the
way the merge consumes it. Each rejection names itself on stderr. Rejected
shapes: not exactly one JSON value; top level not an object; `blockers` /
`suggestions` not an array of objects; a finding's `location` not a string;
`questions` not an array; `summary` not a string.

Rejecting an artifact keeps that lane's failure local — exit 4, coverage
degraded.

The line between the two failure classes is whether the lane produced any bytes
at all. An artifact with content the merge cannot consume, including one
holding only whitespace, is the lane answering unusably (4). An absent or
zero-byte artifact, or a lane that exited 0 leaving nothing, is the lane never
answering (5).

A lane that died to a signal — the lane child reaped with a status of 128+N
where N is a signal the shell can name, or its CLI killed and classified by the
child (exit 6) — is a KILL, recorded as
`status: "killed"` and reported with the signal's name: the reviewer was taken
away by something outside the run, not refused, and folding that into "failed"
is how a recurring killer stays invisible.

When **every** lane fails there is no artifact and the run takes the aggregate
of those classes: 4 when at least one lane answered unusably — its own exit 4,
an artifact the merge could not consume, or a response-defect exit 1 — else 6
when any lane was killed, and 5 when no lane ever answered.
