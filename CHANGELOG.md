# Changelog

## Unreleased

- **orch (breaking, removal): the legacy consumer script pair is gone.**
  `skills/orch/scripts/ci/{review-predicate.sh,approval-refire.sh}` and
  their tests existed only for pre-v2 hyprtrade, which completed its v2
  cutover; the canonical engine is the review-gate skill (predicate +
  single writer), vendored via `vstack refresh`. The orch DEVELOPMENT.md
  "Review-gate reference scripts" section now points there.

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
