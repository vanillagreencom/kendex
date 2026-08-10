# Changelog

## Unreleased

- **agents: the skill-failure reporting blockquote is condensed to a
  three-line pointer** (VST-177). The full routing/attribution decision tree
  now lives in one canonical file, `docs/skill-failure-reporting.md`, which
  the CLI installs and refreshes at `.agents/skill-failure-reporting.md`
  (project scope) or `<platform config dir>/vstack/skill-failure-reporting.md`
  (global scope) whenever it generates agents. Source agent bodies carry a
  `{{VSTACK_FAILURE_REF}}` placeholder; generation substitutes the resolved
  path for the target scope, so generated files never embed a wrong-platform
  path. Regenerating agents shrinks every generated agent file by ~1.5 KB.

- **CLI: shared `all` key for `[agent-launch-instructions]`,
  `[agent-additional-instructions]`, and `[skill-instructions]`** (VST-178
  mechanism). The value under `all` (alias `"*"`) applies to every agent or
  skill; when an item also has its own entry, both render — shared first,
  then the item's own, separated by a blank line. In generated agent files
  the shared portion is wrapped in invisible HTML-comment markers
  (`<!-- vstack:shared-instructions:start/end -->`), so re-extraction drops
  it structurally even after the `all` value changes or is removed.
  **Breaking**: `all` is now a reserved item name — installing an agent,
  skill, or hook named `all` is rejected with an explanatory error.

- **second-opinion: `AGENTS.md` joined the default review-instruction globs**,
  and nested `AGENTS.md` files governing the changed paths are collected too
  (parents before children). **Migration note for existing installs**: skill
  seeding never overwrites an existing `SECOND_OPINION_REVIEW_INSTRUCTIONS`
  key, so a `vstack.settings.toml` that carries the previous default keeps the
  old list — update the pinned value to
  `"AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md"`
  (or delete the key to track the default) to pick up AGENTS.md coverage.

- **orch: local pre-PR review passes are budgeted per pushed head, not per
  submission** (VST-153, follow-up to the vstack#1141 `reviewed_head` artifact
  stamp). `submit-pr` § 1.2 checks the budget through the new
  `local-review-budget` helper: `pr_local_review.passes` now counts against
  `pr_local_review.reviewed_head` (recorded from the review artifact's
  `qa_metadata.reviewed_head` after each counted pass), and a head change
  resets the round — GitHub bots re-review every push, so a new head is a new
  round; the 2-pass cap binds only within a single head.

- **orch (breaking, removal): the legacy consumer script pair is gone.**
  `skills/orch/scripts/ci/{review-predicate.sh,approval-refire.sh}` and
  their tests existed only for pre-v2 hyprtrade, which completed its v2
  cutover; the canonical engine is the review-gate skill (predicate +
  single writer), vendored via `vstack refresh`. The orch DEVELOPMENT.md
  "CI Triggering Patterns" section (including its "Review-gate engine"
  bullet) is rewritten as v2 guidance and points there.

- **review-gate v2 (breaking, consumer CI): one writer, review-only gate.**
  The gate now answers exactly one question — has this exact head been
  reviewed? — and never polices CI; whether untested code can merge is
  branch protection's job (adoption precondition: a merge queue requiring
  the test aggregate, or no held-back jobs). One default-branch-defined
  workflow (`templates/review-gate-writer.yml`) replaces the four-workflow
  mesh; deleted with it: `approval-refire.sh`, the `approval-rerun.yml` /
  `approval-sweep.yml` templates, the post-approval rerun/proof machinery,
  and the `REVIEW_GATE_TRUST_PR_WORKFLOWS` / `REVIEW_GATE_MAX_RERUN_ATTEMPTS`
  keys. Consumers migrate per `references/adoption.md` ("Migrating a v1
  consumer"): writer workflow in, rerun/sweep and predicate-reading gate
  jobs out, docs moved to `REVIEW_GATE_OVERRIDE_CONTEXT` (legacy
  `REVIEW_GATE_OUTAGE_CONTEXT` still resolves). SECURITY: the predicate now
  reads the per-commit statuses LIST endpoint, so
  `REVIEW_GATE_STATUS_PUBLISHER_REJECT` actually rejects
  workflow-minted statuses (the combined endpoint nulled App creators and
  made the list inert); while the list is configured, a status with no
  creator login is not evidence. vstack's own CI adopts the fast/full
  split: heavy suites run only in the merge queue.

- **review-gate (breaking, consumer CI):** the `approval-sweep.yml` template
  now requests `issues: write` (previously `read`) for the sustained-failure
  escalation step's rolling incident issue. Consumers adopting the updated
  scaffold must grant the permission — or drop the escalation step to stay on
  `issues: read`.
