# Completion-artifact reference

Full contracts behind the `review-artifact-check` / `dev-return-write` / `dev-round-write` / `dev-artifact-check` rows and the round-closure mechanics in [../SKILL.md](../SKILL.md). Each script's `--help` carries its flag reference.

## `review-artifact-check`

Validates a reviewer's on-disk JSON artifact — exists, `mtime >=` delegation epoch, `jq -e '.verdict'`, and no self-reported no-review — and prints `{ok, path, reason}`. It is the sole review-pr completion condition.

- An artifact whose `qa_metadata` admits no review happened (`review_performed: false` or a no-scope reason) is rejected with reason `no_review` regardless of verdict.
- An artifact declaring `qa_metadata` whose `blockers[]`/`suggestions[]` are lost (missing/non-array), or whose present items omit a required `review-finding` field — including the routing-critical `category ∈ {fix,issue}` on suggestions — is rejected with reason `incomplete`, plus a `detail` field naming the offending item and field. Artifacts without `qa_metadata` are unaffected.
- `--file <path> [delegated_at_epoch]` validates one explicit artifact; the optional boundary applies the same freshness gate, so a stale or misdated external review is rejected.

## `dev-return-write`

Deterministically writes a dev agent's round-scoped completion artifact (`[WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`) with `jq`, atomically (temp+mv), instead of hand-authoring the JSON, and prints the artifact's absolute path. It writes `round_id`/`schema_version` and validates its inputs (exit 2 on a bad `--kind`, missing required argument, malformed `--validate`, bad `--item` DECISION, empty REASONING, an `--issue`/`--round-id` outside `^[A-Za-z0-9._-]+$`, or a `fix`/`--bundled` invocation with no `--item`). `--kind analysis` spells a read-only investigate-and-recommend round truthfully: it requires exactly one of `--summary TEXT` (inline — so a harness-refused file write is not a dead end) or `--summary-file PATH` (the recommendation/evidence) and rejects `--commit`/`--validate`/`--validate-note`/`--item`/`--bundled`, omitting those keys from the artifact so no validation outcome can be asserted for a round that ran none. Flags: `dev-return-write --help`. Canonical schema: `../schemas/dev-return.md`.

## `dev-round-write`

Orchestrator-side twin of `dev-return-write` for the round's *input*: persists a fix round's delegated item set to `[WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` (atomic temp+mv, prints the path) at the moment the round is stamped, so the set survives the orchestrator's context. Item sources (mutually exclusive): `--items-file JSON_PATH` — a `{n, text}` array built with the harness file-write tool, the default route because real review blocks carry backticks that strict classifiers reject even quoted — or inline `--item N TEXT` per item when every text is plain (N = the delegated `#[N]` number, a canonical integer, unique; TEXT = the item's formatted block verbatim). Records are immutable per round: identical re-invocation is idempotent, different content under the same round id exits 2 (a changed delegation mints a new round id). The record carries the internal `round_id` token, mirroring the dev-return binding, and is read by `dev-artifact-check --expect-items-from-round`, by a respawned dev agent recovering its items, and by the `ok==false` tail-reconciliation nudge. Flags: `dev-round-write --help`. Canonical schema: `../schemas/dev-round.md`.

## `dev-artifact-check`

Validates a dev agent's round-scoped completion artifact and prints `{ok, path, reason}` (`valid`|`missing`|`invalid`|`incomplete`, gates ordered missing → invalid → incomplete → valid). Round mode (`--worktree WT --issue ISSUE --round-id RID [--expect-items N,N,... | --expect-items-from-round]`) resolves `WT/tmp/dev-return-ISSUE-RID.json` and requires:

- the internal `round_id == RID` — clock-independent identity; there is no mtime gate;
- type-strict scalars: `.kind` ∈ implement|fix|analysis; `.issue`/`.branch` non-empty strings; `.round_id` string; `.schema_version` number. implement/fix additionally require `.commit`/`.validate` non-empty strings; `analysis` (complete-without-code, vstack#952) requires the inverse — no `.commit`/`.validate`/`.validate_note` key present at all (their presence is `invalid`);
- the items rule: the expected set is the exact delegated set for fix rounds — supplied inline (`--expect-items N,N,...`) or, preferably, read from the persisted round record (`--expect-items-from-round` resolves `WT/tmp/dev-round-ISSUE-RID.json`, validates the record's full schema — internal `round_id == RID`, matching `issue`, non-empty `items[]` of unique integer `n` — and refuses to run — exit 2, never a silent downgrade — when the record is missing, token-mismatched, or malformed; the count-vs-set `hint` is never emitted for a from-round set). Otherwise items must be non-empty and well-formed for fix/bundled, while `implement` allows `items: []`. `analysis` completeness is its `.summary` (the recommendation) being a non-empty string, else `incomplete`.

A fresh valid artifact for the current round lets `dev-start.md` § 3 accept a completion whose return message never arrived because the validation outlasted the turn; git/tracker corroboration stays in orch. `--file <path> [--round-id RID] [--expect-items ...]` validates one explicit artifact. One identity model (round id) — no mtime gate, no legacy positional mode.

## Round-closure mechanics

Deep halves of SKILL.md § Wait for Agent Return Before Acting:

- **Watchdog mechanisms are harness-specific; the requirement is uniform.** Claude Code: a background shell that re-invokes the main loop on exit. Pi: a `bg_task` timer — it emits no exit wake, so pair it with the per-wake check as backstop. Codex/OpenCode: scheduled re-entry or a session-file poll. The watchdog fires once at `dev_delegated_at + quiet_window`, runs A/B if the round is still outstanding (else no-op), and re-arms only on entering a new nudge/escalation step — never a busy poll.
- **The round token binds A to exactly THIS delegation's receipt** (`tmp/dev-return-[ISSUE_ID]-[dev_round_id].json`, internal `round_id` matched), so a stale, same-second, cross-group, or cross-workflow receipt at a shared path can never be mis-accepted.
- **A path whose agent writes no dev-return artifact** (`ci-fix.md` § 3.2 pushes directly) always has A `ok==false`: it is accepted by its own return message and the escalation ladder on a real stall, outside the A/B table, never by a stale artifact.
- **Composite B never accepts on its own.** Return-message timeout, clean git status/diff/log, and no modified files reflect worktree state only. The sole positive signal that overrides a missing return is a valid `dev-artifact-check` for the current `dev_round_id`; every path converges on it.

## Dev-vs-reviewer asymmetry (intentional — do not "align")

Reviewers have no independent git/tracker signal — their JSON *is* the
deliverable — so a reviewer `ok==false` after a return is `incomplete` →
re-delegate (`review-pr.md` § 3.1). Dev's B signal only distinguishes "code
landed, recover the tail" (`ok==false` + pass → one report-only nudge) from
"not done" (`ok==false` + fail → escalate); neither branch re-runs the work,
and neither accepts without the round-scoped artifact.
