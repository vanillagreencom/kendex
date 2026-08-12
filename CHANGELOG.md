# Changelog

## Unreleased

- **reviewer: ground-up rewrite driven by 24-PR escape mining; new
  `preflight` skill; `reviewer-structure` retired.** A survey of the last 6
  PRs in each of four consuming repos classified every bug that escaped
  internal review; the reviewer skill and all reviewer agents were rewritten
  from scratch around those classes, on the principle that frontier reviewers
  need domain probes and contracts, not technique tutorials. Cut outright:
  the duplicated field tables, repeated artifact-naming warnings, the inlined
  Harness-Safe Shell essay (orch is the canonical home; the worked backtick
  example moved to `references/codex-runtime.md`), the central scope-boundary
  table (each agent file owns its scope and its leave-to-peers line),
  reviewer-side decider recovery (a broken decision path is noted and
  reviewed without — decision context is the orchestrator's to provide; the
  `decider` and `github` skill dependencies drop with it), the perf agent's
  33-row resource library, and every generic read-the-architecture-docs
  boilerplate section. In their place: every review workflow mandates a
  pre-return self-check with orch's `review-artifact-check`, the ethos adds
  "report the class, not the instance", and re-review rounds scope to the
  fix diff plus blast radius while sweeping each fixed defect's class.
  Agents carry mined high-yield probes instead of generic checklists:
  fail-open catalogue (`reviewer-error`), must-fail controls and assertion
  tightness (`reviewer-test`), claim/derivation/citation verification
  (`reviewer-doc`, now xhigh effort — doc drift is the largest escape class),
  boundary probes (`reviewer-correctness`), ownership-gating class
  enforcement (`reviewer-security`), file/process races (`reviewer-safety`),
  mechanism-over-shapes (`reviewer-quality`), spec review (`reviewer-arch`).
  Perf benchmark recording contracts live in
  `skills/reviewer/references/perf-qa.md`, loaded only by the perf agent.
  A new `code-quality` skill (VST-212, modeled on Turso's) gives dev agents
  the authoring mirror of the reviewer probes — no fail-open branches,
  prove-your-guards, comment do's/don'ts (why-not-what, no temporal markers
  or review archaeology), over-engineering and cleanup rules — one generic
  copy upstream, repo specifics via the `[skill-instructions]` seam; wired
  into `[role-skills] engineer`.
  Size-ratchet enforcement moves earlier without changing semantics: the
  pre-commit hook now runs the repo's own ratchet script — adoption-gated on
  a baseline existing, so installing the skill alone never starts enforcing
  — and dev-implement § 5 runs it pre-PR, replacing the CI-round-trip
  discovery path; the reviewer-side duplicate of the size rule is gone with
  `reviewer-structure`, leaving the script as the single source of truth.
  **Breaking**: the `reviewer-structure` agent is retired — its file-size job
  is size-ratchet's, TODO hygiene is preflight's, god objects and test
  placement fold into `reviewer-quality`; remove it from consuming-repo
  configs on next refresh. The new `preflight` skill is a diff-scoped,
  fail-only deterministic checker (shell syntax + shellcheck error lanes,
  masked-return/unchecked-`mktemp` fail-open lint, dead doc citations,
  unlinked TODO markers, JSON/TOML syntax) wired into dev-implement § 5, the
  pre-commit hook, `[role-skills] engineer`, and a PR-time CI dogfood job.
  Consumer adoption: `[agent-skills]`/`[role-skills]` are project-owned
  after install, so existing consumers opt in by adding `preflight` and
  `code-quality` to their own config and running `vstack refresh`; the
  updated pre-commit hook arrives with refresh and its preflight lane
  self-gates on the skill being installed. CI use of preflight, like
  review-gate, requires the installed skill committed to the repo.

- **second-opinion: a multi-lane review no longer loses its verdict when
  scratch space disappears mid-run** (VST-221 / #1229). The union merge used
  to re-wrap each lane's review into a `wrap-<lane>.json` file inside the
  run's `mktemp -d` directory and read those files back at the end. Anything
  clearing that directory while lanes ran — the reviewed repo's own agent CLI,
  a sandbox, a tmp reaper — made the parent report both healthy lanes as
  "unparseable" and exit 4 with no external verdict, even though valid lane
  artifacts sat intact beside the union path. Without `--output` the lane
  reviews lived in that directory too, so clearing it dropped a model's real
  findings while the union still published a pass.

  Lane scratch now has one owner and one rule: the run creates exactly one
  directory under `TMPDIR`, it holds nothing but the per-lane stderr captures,
  and each lane's review is held in memory from the moment it is reaped —
  never read back from that directory. Losing that directory costs the log
  replay (reported as such) and never a verdict. Where a lane's review sits
  until it is reaped depends on the mode: with `--output` it is the durable
  sibling `<output>.<target>.json`, beyond the reach of any temp-space actor;
  without `--output` it is an ordinary temp file, so an actor that removes
  temp *files* still costs that lane — but loudly, with coverage `"degraded"`,
  the lane recorded at exit 5, and the loss named on stderr, never as a silent
  pass. Lane children now run under a restrictive umask, so the sidecars they
  write in temp space are owner-only.

  Artifact handling got stricter in the same pass. An artifact is accepted
  only if it holds exactly one JSON object carrying the shape the union merge
  consumes: previously an artifact that held no JSON value at all merged as a
  phantom healthy lane (`jq` exits 0 printing nothing for it) and could
  publish a pass over a real blocker, while one carrying a malformed finding —
  `blockers: ["bad"]` — aborted the whole merge and delivered no union even
  when the other lane was fine. Both are now that lane answering unusably
  (exit 4, coverage degraded), and the healthy lanes still publish. Each lane
  artifact is read exactly once, so the reported cause is the one that
  actually rejected it. A lane that exits 0 with no usable artifact is
  recorded with the never-answered code 5 instead of a bare `exit 0`, and the
  "union of N lanes" line counts the lanes the written artifact carries.

- **orch: claude handoff lanes launch autonomous and verify brief delivery**
  (VST-191 / #1173). `open-terminal` now renders a permission argument into
  claude lane launch commands, sourced from the new
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` `[env]` key and defaulting to
  `--dangerously-skip-permissions` — handoff is launch-only autonomy, and a
  session in prompting mode stalled on its first tool call with nobody
  attached. A prompting override still launches but warns loudly that handoff
  autonomy is void. On tmux lanes the launcher now verifies the CLI-arg brief
  actually reached the TUI (first-run dialogs were silently consuming it),
  re-sends it once into the composer if absent, and otherwise emits a
  per-lane failure and exits nonzero instead of reporting success — the
  claude-path sibling of the #976 codex kickoff fix.

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
