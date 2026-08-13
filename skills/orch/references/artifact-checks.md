# Completion-artifact reference

Full contracts behind the artifact rows and the round-closure mechanics in [../SKILL.md](../SKILL.md). Each script's `--help` carries its flag reference.

## `review-artifact-check`

Validates a reviewer's on-disk JSON artifact — exists, `mtime >=` the delegation epoch, `jq -e '.verdict'`, no self-reported no-review — and prints `{ok, path, reason}`. It is the sole reviewer completion condition.

- An artifact whose `qa_metadata` admits no review happened (`review_performed: false`, or a no-scope reason) is rejected with reason `no_review` whatever its verdict says.
- An artifact declaring `qa_metadata` whose `blockers[]`/`suggestions[]` are missing or not arrays, or whose present items omit a required `review-finding` field — including the routing-critical `category ∈ {fix,issue}` on suggestions — is rejected with reason `incomplete` plus a `detail` field naming the item and field. Artifacts without `qa_metadata` are unaffected.
- `--file <path> [delegated_at_epoch]` validates one explicit artifact; the optional boundary applies the same freshness gate, so a stale or misdated external review is rejected.

## `dev-return-write`

Writes a dev agent's round-scoped completion artifact (`[WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`) with `jq`, atomically (temp + `mv`), and prints its absolute path. It writes `round_id`/`schema_version` and validates its inputs, exiting 2 on a bad `--kind`, a missing required argument, a malformed `--validate`, a bad `--item` DECISION, empty REASONING, an `--issue`/`--round-id` outside `^[A-Za-z0-9._-]+$`, or a `fix`/`--bundled` invocation with no `--item`.

`--kind analysis` spells a read-only investigate-and-recommend round truthfully: it requires exactly one of `--summary TEXT` (inline, so a harness-refused file write is not a dead end) or `--summary-file PATH`, and rejects `--commit`/`--validate`/`--validate-note`/`--item`/`--bundled`, omitting those keys so no validation outcome can be asserted for a round that ran none. Canonical schema: [`../schemas/dev-return.md`](../schemas/dev-return.md).

## `dev-round-write`

The orchestrator-side twin for the round's *input*: persists a fix round's delegated item set to `[WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json` at stamp time, so the set survives the orchestrator's context. Item sources are mutually exclusive — `--items-file JSON_PATH`, a `{n, text}` array built with the harness file-write tool (the default route, because real review blocks carry backticks strict classifiers reject even quoted), or inline `--item N TEXT` when every text is plain.

Records are immutable per round: an identical re-invocation is idempotent, different content under the same round id exits 2, and a changed delegation mints a new round id. The record carries the internal `round_id` token and is read by `dev-artifact-check --expect-items-from-round`, by a respawned dev agent recovering its items, and by the tail-reconciliation nudge. Canonical schema: [`../schemas/dev-round.md`](../schemas/dev-round.md).

## `dev-artifact-check`

Validates a dev agent's round-scoped artifact and prints `{ok, path, reason}`. The gates are ordered missing → invalid → incomplete → valid, and the first failure wins. Round mode (`--worktree WT --issue ISSUE --round-id RID [--expect-items N,N,... | --expect-items-from-round]`) resolves `WT/tmp/dev-return-ISSUE-RID.json` and requires:

- the internal `round_id == RID` — clock-independent identity, no mtime gate;
- type-strict scalars: `.kind` ∈ implement|fix|analysis; `.issue`/`.branch` non-empty strings; `.round_id` a string; `.schema_version` a number. implement and fix additionally require non-empty `.commit`/`.validate`; `analysis` requires the inverse — no `.commit`, `.validate`, or `.validate_note` key present at all, since their presence would assert a validation that never ran;
- the items rule. For fix rounds the expected set is the exact delegated set, supplied inline (`--expect-items`) or, preferably, read from the persisted record (`--expect-items-from-round`, which resolves `WT/tmp/dev-round-ISSUE-RID.json`, validates its full schema — internal `round_id == RID`, matching `issue`, non-empty `items[]` of unique integer `n` — and refuses to run with exit 2, never a silent downgrade, when the record is missing, token-mismatched, or malformed). Otherwise items must be non-empty and well-formed for fix and bundled rounds, while `implement` allows `items: []`. An `analysis` round's completeness is a non-empty `.summary`.

`--file <path> [--round-id RID] [--expect-items ...]` validates one explicit artifact. One identity model — round id — with no mtime gate and no legacy positional mode. The script never runs git or tracker checks; that corroboration and exact-commit binding live in the orch acceptance tables.

## Round-closure mechanics

- **Watchdog mechanisms are harness-specific; the requirement is uniform.** Claude Code: a background shell that re-invokes the main loop on exit. Pi: a `bg_task` timer, which emits no exit wake, so pair it with the per-wake check. Codex and OpenCode: scheduled re-entry or a session-file poll. The watchdog fires once at `dev_delegated_at + quiet_window`, runs A/B if the round is still outstanding, and re-arms only on entering a new escalation step.
- **The round token binds A to exactly this delegation's receipt**, so a stale, same-second, cross-group, or cross-workflow receipt at a shared path can never be mis-accepted.
- **A path whose agent writes no dev-return artifact** (`ci-fix.md` pushes directly) always has A `ok==false`: it is accepted by its return message and the escalation ladder, outside the A/B table, never by a stale artifact.
- **Composite B never accepts on its own.** A return-message timeout, clean git status, and no modified files reflect worktree state only. The one positive signal that overrides a missing return is a valid `dev-artifact-check` for the current `dev_round_id`.

## Dev-vs-reviewer asymmetry (intentional — do not "align")

Reviewers have no independent git or tracker signal — their JSON *is* the deliverable — so a reviewer `ok==false` after a return is `incomplete` and gets one re-delegation. Dev's B signal only distinguishes "code landed, recover the tail" (`ok==false` + B pass → one report-only nudge) from "not done" (`ok==false` + B fail → escalate). Neither branch re-runs the work, and neither accepts without the round-scoped artifact.
