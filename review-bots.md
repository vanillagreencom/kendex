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

These are known, deliberate trade-offs. Raising them again is noise:

- **No cross-surface evidence ordering.** All four evidence surfaces —
  review objects, check runs, commit statuses, and SHA-bound trusted
  comments — resolve newest-decides *within* the surface; nothing orders
  evidence *across* surfaces. A finding that assumes one surface should
  supersede another asks for a design that does not exist.
- **Transient windows heal by convergence.** A state change landing
  between two reads is corrected on the next convergence pass, at most
  15 minutes later. Do not propose locks for these windows.
- **A final docs-only push may keep earlier review evidence.** This is
  deliberate; policy and instruction files are excluded and always get a
  fresh review. Do not flag it as a gate hole.
- **A gate success just before a push is not a fail-open.** The next
  convergence supersedes it, and the merge queue re-checks at admission.
- **Threads arriving after merge-queue admission are procedural, not a
  gate defect.** The handling is dequeue → fix → re-arm.

## Trust model (context, not a finding surface)

Review evidence is formal review objects from trusted logins (or the other
documented evidence forms in `skills/review-gate/references/settings.md`).
Comment text, emoji reactions, and thumbs-ups are never approval — by
design. Do not recommend parsing them.
