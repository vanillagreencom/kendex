# Reviewer guidance for GitHub review bots

Instructions for automated PR reviewers (Copilot code review, Codex, and
any successor). This file is reviewer context only — agent sessions must
not load it as working instructions (that is why it is not in `AGENTS.md`).

## Accepted residual classes (decided — do not re-raise)

These are known, deliberate trade-offs. Raising them again is noise:

- **No cross-surface evidence ordering.** Nothing orders evidence *across*
  the four surfaces (review objects, check runs, commit statuses, trusted
  comments) — a finding that assumes one surface supersedes another asks
  for a design that does not exist. Each surface's own resolution
  semantics are specified in the predicate header
  (`skills/review-gate/scripts/review-predicate.sh`) — check there before
  asserting supersession behavior within a surface.

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
- **An adopted review-gate workflow is validated by verbatim EQUALITY
  against the shipped template.** `validate-workflow.sh` asks one question —
  is this copy still `templates/review-gate-writer.yml`? — and re-derives
  nothing about what the workflow means, so a finding that it fails to
  evaluate an expression or reason about a job's permissions is answering the
  wrong question of the wrong tool. What the TEMPLATE means is answered
  upstream in `skills/review-gate/tests/review-writer-template.test.sh`: the
  `[template]` block derives it from the shipped template alone, and the
  `relay:` battery executes the relay step against a gh stub. That block is
  closed over one named set: its preamble names the set and points at
  `skills/review-gate/DEVELOPMENT.md` § The workflow template for the classes
  outside it. A gap worth naming is a property inside that set which is
  neither checked nor in the block's ledger.

- **No test-coverage asks for instruction markdown or for `tools/guard`
  rules in a change that adds no guard test lane.** What a test must cover is
  `.github/instructions/tests.instructions.md`. A markdown contract lint pins
  tokens, never sentences, so a claim that lives only in prose has no lint
  coverage and none is asked for.
- **The PreToolUse commit hook reads git words, not shell expansion.**
  Quoted flags, `flag=` assignments, aliases, and other spellings the shell
  would have to expand are outside its contract; the installed git hook is
  the guarantee in an armed repo.
- **What `.git/hooks` holds is a consent record, not an integrity check.**
  It answers "did somebody here arm this repository", which is what the
  PreToolUse lane needs from the marker plus execute bit, and what
  `kendex check` needs from the helper's presence before it runs the
  package's scripts. Neither answers whether a hook body still reaches
  those scripts — an executable hook whose delegating line is commented out
  reads armed, and that is accepted: `.git/hooks` is never cloned, so
  reaching that state takes local write access, and anyone with it bypasses
  any predicate by writing a passing hook outright. Integrity lives in the
  package's own `--check`, which `kendex guard check` and `kendex check`
  both ask. Settled by KEN-670; marker-trust findings are not a finding
  surface.
- **Windows-only resolution paths (PATHEXT, `.cmd` shims) are out of
  scope until a Windows report exists.**

## Trust model (context, not a finding surface)

Review evidence is formal review objects from trusted logins (or the other
documented evidence forms in `skills/review-gate/references/settings.md`).
Comment text, emoji reactions, and thumbs-ups are never approval — by
design. Do not recommend parsing them.

## Reply contract

`AGENTS.md` § Code Review Rules is the contract. Read it there.
