# Completion-artifact reference

Cross-script routing behind the artifact rows in [../SKILL.md](../SKILL.md). Each script's `--help` is its authoritative contract; nothing here restates one.

| Script | Role |
|--------|------|
| `review-artifact-check` | Validates a reviewer's on-disk JSON artifact — the sole reviewer completion condition; review-pr.md § 3.1 relays a rejection's `detail` on the single permitted re-delegation. |
| `dev-return-write` | Writes a dev round's completion artifact atomically. Schema: [`../schemas/dev-return.md`](../schemas/dev-return.md). |
| `dev-round-write` | Orchestrator-side twin persisting a fix round's delegated item set at stamp time; immutable per round. Schema: [`../schemas/dev-round.md`](../schemas/dev-round.md). |
| `dev-artifact-check` | Validates a dev round's artifact by round id and answers `accept`/`wait`/`retry`. Tracker corroboration and exact-commit acceptance binding stay in the orch acceptance tables. |

## Round-closure mechanics

- **The watchdog IS the check in blocking mode**: `dev-artifact-check --wait <quiet_window> …` (reviewers: `review-artifact-check … --wait`) polls on-disk state and returns the moment a fresh artifact lands or at the deadline — return-message delivery is never load-bearing. Per-harness backgrounding is in each check's `--help`. Run A/B on its return if the round is still outstanding; re-arm only on entering a new escalation step.
- **The round token binds A to exactly this delegation's receipt.**
- **A path whose agent writes no dev-return artifact** (`ci-fix.md` pushes directly) always has A `verdict=wait`: accepted by its return message and the escalation ladder, never by a stale artifact.
- **Composite B never accepts on its own.** A return-message timeout, clean git status, and no modified files reflect worktree state only. The one positive signal that overrides a missing return is a valid `dev-artifact-check` for the current `dev_round_id`.

## Dev-vs-reviewer asymmetry (intentional — do not "align")

A reviewer invalid artifact after a return is `incomplete` and gets one re-delegation. Dev's verdict distinguishes a still-running round (`wait` — B pass gets one report-only tail nudge, B fail escalates at the deadline) from a present-but-failing receipt (`retry` — never accepted, never treated as absent). Neither branch re-runs the work, and neither accepts without the round-scoped artifact.
