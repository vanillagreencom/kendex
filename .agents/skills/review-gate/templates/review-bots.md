# Reviewer guidance for GitHub review bots

Instructions for automated PR reviewers (Copilot code review, Codex, and
any successor). This file is reviewer context only — agent sessions must not
load it as working instructions, which is why its content is never inlined
into `AGENTS.md`. A one-line pointer there, scoped to review bots, is how the
bots that read `AGENTS.md` find this file.

Everything outside the marked block at the end came from the shipped
`review-gate` template
(`.agents/skills/review-gate/templates/review-bots.md`); this repo's own
entries go inside the block. Repo-owned after the copy: when the engine
changes, bring the text outside the block back into step with the template
BY HAND. Copying the template over this file replaces the block with the
template's placeholder.

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
  engine header comment, or a note in
  `.agents/skills/review-gate/references/`), do not raise the same finding
  class again on a later round unless the relevant code changed. Repo rules
  cited by bots live in `.github/instructions/` — check there before
  asserting a rule.

## Accepted residual classes of the review gate (decided — do not re-raise)

Properties of the shipped engine, not of this repo. Raising them again is
noise:

- **No cross-surface evidence ordering.** Nothing orders evidence *across*
  the four surfaces (review objects, check runs, commit statuses, trusted
  comments) — a finding that assumes one surface supersedes another asks
  for a design that does not exist. Each surface's own resolution
  semantics are specified in the predicate header
  (`.agents/skills/review-gate/scripts/review-predicate.sh`) — check there
  before asserting supersession behavior within a surface.
- **Transient windows heal by convergence.** A state change landing
  between two reads is corrected on the next convergence pass. That pass is
  scheduled and best-effort — it can slip under load — so a window standing
  open is not proof of a defect, and a gate that stays stale is a delivery
  question, not a locking one. Do not propose locks for these windows.
- **A final docs-only push may keep earlier review evidence.** Deliberate
  wherever `REVIEW_GATE_CARRY_FORWARD` names the `docs` class. Policy and
  instruction files are excluded wherever `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`
  names them, and then always get a fresh review. Do not flag the carry
  itself as a gate hole.
- **A gate success just before a push is not a fail-open.** The next
  convergence supersedes it, and the merge queue re-checks at admission.
- **Threads arriving after merge-queue admission are procedural, not a
  gate defect.** The handling is dequeue → fix → re-arm.
- **An adopted review-gate workflow is validated by verbatim EQUALITY
  against the shipped template.** `validate-workflow.sh` asks one question —
  is this copy still `templates/review-gate-writer.yml`? — and re-derives
  nothing about what the workflow means. What the template MEANS is asserted
  upstream in
  `.agents/skills/review-gate/tests/review-writer-template.test.sh`, which
  is the only place that can answer it. A finding that
  `validate-workflow.sh` fails to evaluate an expression, enumerate an
  activity type, or reason about a job's permissions is settled: name the
  gap in the upstream suite instead.

## Trust model (context, not a finding surface)

Review evidence is formal review objects from trusted logins (or the other
documented evidence forms in
`.agents/skills/review-gate/references/settings.md`). Comment text, emoji
reactions, and thumbs-ups are never approval — by design. Do not recommend
parsing them.

## Reply contract

Author replies to findings are exactly `Fixed in <sha>`, `Declined: <reason>`,
or `Tracked: <ISSUE-ID>` / `#<n>`. The merge gate turns red on a tracking
claim naming no issue, so a decline without "tracked" wording is deliberate.
Do not re-raise a finding class answered `Declined:` unless the relevant
code changed since.

<!-- BEGIN repo-specific accepted residuals -->

## Accepted residual classes of this repo (decided — do not re-raise)

This repo's own deliberate trade-offs, one bullet each. A repo with none
yet keeps the section and the placeholder.

- (none recorded)

<!-- END repo-specific accepted residuals -->
