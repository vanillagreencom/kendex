# Reviewer guidance for GitHub review bots

Instructions for automated PR reviewers (Copilot code review, Codex, and
any successor). This file is reviewer context only — agent sessions must
not load it as working instructions (that is why it is not in `AGENTS.md`).

## Review economics

Every push triggers a full re-review by every bot, and PRs here are pushed
at agent speed — long finding tails are expensive in rounds, not just
tokens. Calibrate accordingly:

- **Consolidate, don't drip.** Surface everything you have about the
  current diff in ONE round. A finding you could have raised last round
  but held back costs a full re-review cycle.
- **Severity honesty.** Merge-blocking findings are: correctness bugs,
  fail-open paths in gating/CI code, security holes, data loss. Wording
  preferences, style nits, and speculative hardening on already-fail-closed
  paths are suggestions — batch them, mark them non-blocking, or omit them
  on late rounds.
- **Do not re-raise declined findings.** When a finding was declined with
  a documented rationale (a reply on the thread, a settings comment, an
  engine header comment, or a note in `skills/review-gate/references/`),
  do not raise the same finding class again on a later round unless the
  relevant code changed. Repo rules cited by bots live in
  `.github/instructions/` — check there before asserting a rule.

## Accepted residual classes (decided — do not re-raise)

These are known, deliberate trade-offs with rationale recorded where the
decision lives. Raising them again is noise:

- **Per-surface supersession.** Evidence surfaces (review objects, check
  runs, commit statuses, trusted comments) each resolve
  newest-decides *within* the surface; there is no cross-surface
  supersession ordering. Documented in the predicate header.
- **Single-poll races.** The writer converges on its next pass (cron
  floor ≤15 min); a state change landing between two reads is healed by
  convergence, not by adding locks. Transient windows that self-heal via
  converge-all are accepted (includes the writer ordering-guard
  clock-skew window: runner clocks are NTP-synced and the guard defers on
  same-second equality).
- **Evidence carry-forward.** Docs-only deltas carry ancestor review
  evidence by owner decision (`REVIEW_GATE_CARRY_FORWARD = "docs"`).
  Policy-bearing markdown is excluded via
  `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`; the `comments` class
  is deliberately off. The remaining residual is documented in
  `vstack.settings.toml` comments.
- **TOCTOU on gate success posts.** The gate's verdict is recomputed by
  the single writer on every trigger; a success posted just before a new
  push is superseded by the next convergence, and the merge queue
  re-checks at admission. Not a fail-open.
- **Post-enqueue threads.** A review round arriving after merge-queue
  admission can land threads on a queued PR; the documented dequeue →
  fix → re-arm procedure covers it. Not a gate defect.

## Trust model (context, not a finding surface)

Review evidence is formal review objects from trusted logins (or the other
documented evidence forms in `skills/review-gate/references/settings.md`).
Comment text, emoji reactions, and thumbs-ups are never approval — by
design. Do not recommend parsing them.
