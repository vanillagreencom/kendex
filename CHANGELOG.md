# Changelog

## Unreleased

### Breaking

- size-ratchet: the default `SIZE_RATCHET_THRESHOLD` drops from 1000 to 400
  (implementation 400, tests 800). Migration, in this order: declare
  `SIZE_RATCHET_CLASSES` for the repo's test layouts FIRST, then run the check
  and turn each `new offender` line into a `path<TAB>lines` baseline row.
  Freezing before declaring baselines files the test class then makes stale.
  Pinning `SIZE_RATCHET_THRESHOLD = "1000"` keeps the old number.
- hooks: a selected hook whose `event:` is absent from the execution contract
  is now REFUSED at install rather than written (VST-283).

### Added

- growth-guards: `scripts/install-git-hooks` writes the `.git/hooks` shims and
  the `vstack-guards` helper, so the guard chain runs at commit time.
- growth-guards: `install-git-hooks --check` reports read-only whether the
  shims are armed, and `vstack check` folds the verdict in (#1482).
- growth-guards: the pre-commit chain runs `preflight --staged` when that skill
  is installed beside it (VST-310).
- preflight: new `hardcoded-temp-path` lane — an added directory-creating call
  taking a literal `/tmp/…` or `/var/tmp/…` fails, since it escapes TMPDIR
  redirection and leaks (#1481).
- preflight: three added-line lanes — `unwired-suite`, `mktemp-trap` and
  `docs-cited-paths`.
- reviewer: five probes for classes that were being caught downstream instead
  of in review.
- size-ratchet: `--staged` counts index blobs, so growth staged then reverted
  on disk cannot pass a pre-commit gate.
- size-ratchet: per-class thresholds via `SIZE_RATCHET_CLASSES` (glob to
  threshold, first match wins).
- cli: `vstack check` is a process contract — exit `0` clean, `1` drift, `2`
  the check itself failed, with `--quiet`, `--json` and `--offline` (VST-258).
- hooks: one execution contract (an event × harness matrix) decides what
  installing a hook means; every install path, label and published table
  derives from it.
- orch: `reconcile-work-items` reports tracker state written once and never
  re-read — parked containers, stale started items, Done items with unchecked
  acceptance boxes (VST-318).
- pi-agents-tmux: the Agents popup Transcript tab is an event timeline rather
  than raw JSONL; `e` opens the raw file in `$VISUAL`/`$EDITOR` (VST-327).

### Changed

- settings templates: every key's comment condensed to one-line intent plus
  landmines, 922 → 545 lines, zero value changes (VST-317).
- Skill `description:` frontmatter is one or two sentences again across the
  catalog; the longest fell from 810 to 214 characters.
- The `--` rule now names which paths it governs: values from configuration,
  argv or the environment, never a path the script built itself.
- orch: PR-comment triage batches fix rounds per fully-reviewed head, since a
  push restarts every reviewer.
- review-gate: the `/dev/null` force-defaults handle is answered in
  `rg_setting` ahead of every source rather than by an exemption in the
  source-shape check. Behavior unchanged.
- pi-agents-tmux: Monitor task rows show elapsed/total run-time instead of a
  local clock, and timestamps render local human time (VST-316).

### Fixed

- cli: a lock `source` inside `~/.vstack/cache/` resolves as the remote that
  entry clones, not as a local checkout. Every freshness mechanism had been
  skipped at once while each command still reported success (#1495).
- cli: shared configs are read with the parser their own harness uses, never
  the one the file extension suggests.
- cli: structured files are parsed rather than text-matched, so answers no
  longer depend on how a value was spelled.
- cli: commands vstack prints for you to paste are POSIX-quoted, so a source or
  package spelled with shell syntax is passed literally rather than executed.
- growth-guards: a `git grep --cached` scan refuses an unmerged index instead
  of reporting it clean — `conflict-markers` had printed OK mid-conflict, and
  `byte-ceiling` reported zero staged additions (#1510, #1492).
- growth-guards: policy reads fail closed when a git probe cannot answer, and a
  configured policy path is matched literally (#1508).
- growth-guards: policy writes land by same-directory rename, so an interrupt
  cannot leave a truncated settings cache or ratchet baseline (#1502).
- growth-guards: settings resolved from the index no longer read a failing
  `git` as "untracked", which had silently reverted committed policy to the
  built-in default.
- growth-guards: the pre-commit shim reads `size-ratchet --staged`'s outcome, so
  a consuming repo's own replacement skips with a note instead of blocking
  every commit (VST-362).
- growth-guards: every test suite runs against neutralized git configuration
  from one shared `tests/lib/harness.bash`, including config carried in the
  environment (#1500).
- growth-guards: `cleanup-scope.test.sh` asserts over a scratch root the suite
  owns instead of the shared temp namespace, which flaked under concurrency
  (#1501).
- growth-guards: a green suite run prints nothing (#1503).
- preflight: installed-artifact subtrees are out of scope for every lane that
  judges how a file is authored, not just `docs-cited-paths` — the finding
  named an upstream choice the consuming repo cannot fix (#1498, VST-312).
- review-gate: `settings-example-sync.test.sh` can no longer report success for
  comparisons it never made (#1507).
- review-gate: the teardown suite no longer fails when a runner launches it in
  the background; the cause was signal disposition, not process groups (#1506).
- size-ratchet: three fail-closed fixes — `--seed` stays bootstrap-only against
  the committed baseline, and two collector paths that could read as clean.
- size-ratchet: seven fixes absorbed from the forked copy drovr had been
  running, including `--update` converging in one run (DRO-201).
- size-ratchet: `--seed` writes the first baseline from the gate's own
  collector and refuses a live one (VST-328).
- hooks: registered commands resolve from any working directory in a project
  that is not a git repository.
- hooks: a Codex registration is recognised by the script it runs, not the
  literal command string, so a moved project no longer accumulates a second
  handler.
- hooks: one predicate per harness decides which registered command is
  vstack's, and install, removal and presence reports all ask it.
- hooks: `vstack add` checks every selected hook's event against the contract
  before its first write (VST-283).
- hooks: `block-unsafe-rm` declares `harnesses:` without `pi`, which has no
  port of it (VST-283).
- worktree: `create` installs npm dependencies only where npm is the package
  manager, so a pnpm workspace no longer starts dirty (VST-340).
- linear: a truncated `cache issues list` announces itself on stderr with both
  counts instead of returning a bare array that reads as complete (VST-320).
- merge-queue ejection alert: the intake issue is reason-aware — deliberate
  dequeues and conflict re-evaluations get a PR comment only.
- pi-agents-tmux: the idle-stall watchdog skips panes with a pending rate-limit
  retry instead of condemning a throttled agent as stalled (VST-361).

## Earlier (condensed, through 2026-08-16)

### Still-pending consumer actions

No release boundary has passed, so these migration steps from the condensed
span stay required until taken:

- **size-ratchet default threshold drop, 1000 → 400 (breaking):** for a repo
  on the default, in this order: declare `SIZE_RATCHET_CLASSES` for the
  repo's test layouts FIRST, then run the check and turn each reported
  `new offender` line into a `path<TAB>lines` baseline row — freezing before
  declaring would baseline 401–800-line test files the test class then makes
  stale. Declaring `SIZE_RATCHET_THRESHOLD = "1000"` keeps the old number;
  repos already pinning the threshold are unaffected.
- **Retired settings and commands:** delete `REVIEW_RISK_COMMAND`,
  `PR_REVIEW_REFIX_MAX_LINES`, `ORCH_CACHE_DIR`, and
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` from `vstack.settings.toml`; add
  `ORCH_LANE_ALIASES` if you alias lanes. Automation calling any removed orch
  script or passing `github.sh label-add --reason` must update. The retired
  entry points, for sweeping project-owned instructions and automation:
  orch scripts `review-init`, `review-risk`, `refix-route`,
  `local-review-budget`, `list-review-agents`, `tracker-for-issue`,
  `codex-app-agent-preflight` (no replacements); the session-kickstart layer
  `session-init`, `parallel-groups`, `workflows/initialize.md`,
  `workflows/parallel-check.md` (a session picks up the issue and goes; the
  worktree lease claim lives in `start-worktree.md` § 1); orch workflows
  `fix-reconcile.md` (→ TPM audit pipeline + `Closes` linkage),
  `agent-sequencing.md` (→ SKILL.md § Coordination), `recommendation-bias.md`
  (→ `references/finding-disposition.md`); project-management
  `workflows/tpm-audit-project-order.md` (→ a `workflows/tpm-audit.md` mode)
  and `schemas/audit-project-order-output.md` (→ `schemas/audit-output.md`);
  the legacy orch CI pair `scripts/ci/review-predicate.sh` and
  `scripts/ci/approval-refire.sh` (→ the review-gate skill's predicate +
  single writer, vendored via refresh; v1 consumers migrate per its
  `references/adoption.md`); project-management `references/issues.md`,
  `references/initiatives-projects.md`, `references/prioritization.md`
  (their few real constraints relocated into the templates and
  roadmap-create).
- **Hooks with an unsupported `event:` block refresh:** a hook whose `event:`
  is not a row of the execution contract is refused before any mutation —
  the refusal lists the supported events. Change such a hook's event to a
  supported row (or remove the hook) before refreshing.
- **Items named `all` must be renamed or removed before refresh:** `all` is
  now the shared instruction key, so an agent, skill, or hook actually named
  `all` — possible in pre-release installs, whose removal stays supported —
  is rejected by `refresh`; rename or `vstack remove` it first or the
  refresh fails without explaining itself.
- **Roadmap plans need their JSON sidecar:** roadmap-create's legacy
  markdown-parsing fallback is removed — the plan JSON is the contract, and
  `roadmap create` on a markdown-only plan now halts naming the missing
  `**Plan data**` path. Regenerate a pre-sidecar approved plan (or add the
  JSON sidecar) before running roadmap workflows against it.
- **Removed skills and pack (breaking):** before your next `vstack refresh`,
  delete any `iced-shadcn` or `html-artifact` entries from your project's
  `vstack.toml` (`[skill-instructions]`, `[agent-skills]`, `[role-skills]`).
  If you applied the `vanillagreen-themes` pack, run
  `vstack apply vanillagreen-themes --revert` **before** upgrading, while the
  pack is still resolvable; afterwards the managed blocks in Ghostty/tmux
  configs must be removed by hand and the VS Code extension uninstalled
  manually.
- **second-opinion key sweep:** drop `SECOND_OPINION_REVIEW_TARGETS` from
  every file it was seeded into (`vstack.settings.toml`, `.env.local`, and any
  `.env.local.example`/`.env.example` a new checkout copies from), and drop a
  `SECOND_OPINION_TARGET` naming the session's own model — both are now
  refused. Move `SECOND_OPINION_CURRENT_MODEL` out of every project file
  that carries it (`vstack.settings.toml`, `.env`, `.vstack/settings.toml`,
  `.env.local`, and any `.env.local.example`) — a project-file value is
  refused — and export it in the sessions that need it; Pi/OpenCode/Cursor
  and undetected sessions require it. Seeding never overwrites an existing
  `SECOND_OPINION_REVIEW_INSTRUCTIONS` key, so a settings file carrying the
  previous default keeps the old list — update the pinned value to
  `"AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md"`
  (or delete the key to track the default) to pick up AGENTS.md coverage.
- **Vendored guard scripts:** repos vendoring review-gate, size-ratchet, or
  growth-guards must re-vendor to pick up the settings-resolution and
  measurement changes.
- **review-gate v2 CI upgrade:** workflow YAML is repo-owned — `vstack
  refresh` delivers the skill but never the workflows, so refreshing alone
  does not complete the breaking CI upgrade. Replace the rerun/sweep and
  predicate-reading jobs and adopt the relay/converge writer split per
  `skills/review-gate/references/adoption.md`.
- **Remote cache re-clone:** the cache key now derives from repository
  identity, so caches created under the previous scheme are not reused. The
  first `vstack refresh` after upgrading reports each remote source as not
  present and names the `vstack add <source>` that re-clones it — run those,
  or every remote-backed install stays stale; the obsolete directory under
  `~/.vstack/cache/` can be deleted.
- **open-terminal launch flags:** the hardcoded model/effort defaults and
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` are gone, and nothing in scripts,
  settings, or templates supplies a replacement — callers invoking
  `open-terminal` directly must pass model, effort, and permission flags via
  `--launch-flags`, sized to the task, or an unattended handoff launches and
  stalls at its first tool call.
- **Reviewer overhaul opt-in:** `[agent-skills]`/`[role-skills]` are
  project-owned after install, so the retirement of `reviewer-structure` and
  the new deterministic checks do not arrive by refresh alone. Remove
  `reviewer-structure` from your config, add `preflight` and `code-quality`,
  then run `vstack refresh`; CI use of preflight requires the installed
  skill committed to the repo.

### Component rollups

- cli: every git process runs through one hardened constructor — the
  environment's git-config and program-naming variables are dropped, a cache
  entry must prove it is vstack's own clone before any fetch or
  `reset --hard`, remote sources get one cache entry per repository identity,
  and credential-bearing, plaintext-HTTP or unknown-transport URLs are
  refused and never echoed (breaking: older cache entries re-clone) (VST-256).
- cli: propagation fixes — `refresh` seeds missing skill-settings keys into
  self-source repos and refreshes unedited seeded comments behind a
  provenance ledger; `vstack.toml` keeps its trailing newline; a non-TTY
  `add` without `-y` fails actionably; the TUI Updates tab refreshes each
  stale install from its own recorded source; a shared `all` instruction key
  applies to every agent or skill (breaking: `all` is reserved).
- orch: rewritten ground-up (v3) — the issue→dev→review→PR→merge cycle is
  stated once and bounded: bounded review loops, no edge-case churn, declines
  terminal, artifact-based acceptance. Breaking: the session-kickstart layer,
  seven scripts and three workflows are removed, lane launch flags arrive at
  launch time, and QA routing records signals instead of tracker labels.
- orch: a fleet layer — `oversee` runs one shepherded session per queue item,
  unattended by default; `oversee-watch` blocks until the fleet needs the
  overseer (attention, question prompts, exited or idle lanes, usage limits);
  lane launches claim worktrees and auth lanes and verify brief delivery.
- orch: merge-path guards — `queue-wait` dequeues a queued PR on late review
  findings; `PR_REVIEW_QUORUM` holds enqueue until every listed reviewer has
  a head-pinned review and zero unresolved threads; the post-merge base sync
  proves which checkout owns the base branch before advancing it; merged
  worktrees are cleaned by rule; `ORCH_MERGE_AUTONOMY=auto` merges unasked.
- orch/dev: deterministic acceptance — artifact checks print one-word
  verdicts and gained a blocking `--wait`; reviewer artifact paths are
  minted at delegation; a no-CI repo is recognized; a 67-thread triage
  sweep across nine merged PRs fixed every still-live finding.
- review-gate: v2 (breaking, consumer CI) — one default-branch writer
  workflow answering "has this exact head been reviewed?" replaces the
  four-workflow mesh; PR-attached events relay into the writer rather than
  holding its evictable group, so cancelled runs stop pinning PRs at
  `UNSTABLE`; an errored bot review is silence, not approval; settings
  resolution fails closed on unreadable sources (size-ratchet too).
- growth-guards/size-ratchet: growth-guards arrived as the shared check
  family beside size-ratchet — `todo-ban`, `byte-ceiling`, `suppression-ban`
  and a conventional `commit-msg` gate; vstack adopted its own size-ratchet
  gate in CI and at commit time; collection batches `wc` (~8x faster).
- worktree: `remove` no longer tears down a live sibling session's tree — a
  lease whose claiming process is still alive refuses removal, and release is
  bound to a per-claim generation so no race can unlock a live lease.
- hooks: two new `PreToolUse`/`Bash` guards — `block-unsafe-rm` refuses a
  recursive `rm` rooted in a possibly-empty variable, and `block-repo-copy`
  refuses recursive copies of repository or build trees into temp/scratch
  space; the latter ships for Pi as `pi-hooks` `blockRepoCopy` (0.3.0).
- pi-agents-tmux: oneshot transcript records append in event order, so the
  last assistant text a consumer extracts is the last one written (2.8.2).
- linear: fourteen defect fixes led by three that silently corrupted state (a
  failed label lookup wiping an issue's label set, a corrupt cache answering
  "no issues", unvalidated shell arithmetic); blocking relations may cross
  projects; an unknown label refuses the update, never a partial set.
- github: fail-open elimination — `git-diff-summary`, `ci-logs` and the PR
  list commands fail loud instead of fabricating clean answers; `pr-threads`
  filters honestly in every format; `pr-merge` short-circuits merged/closed
  PRs and names queued-merge volatility (breaking: the label commands drop
  `--reason`).
- reviewer/dev/preflight: the reviewer skill and agents rewritten from 24-PR
  escape mining — mined domain probes replace checklists, issue findings
  require an `impact` line, re-review scopes to the fix diff; new `preflight`
  (diff-scoped deterministic fail-only lanes, grown over the period) and
  `code-quality` (prove-your-guards, must-fail controls) skills; dev reduced
  to its contract (breaking: the `reviewer-structure` agent is retired).
- second-opinion: the cross-model guarantee holds in every mode — one roster
  walk excludes the session's own model and refuses when no eligible target
  remains; harness detection beats a contradicting declaration and a
  project-file identity value is refused; lane artifacts moved from shared
  temp into an owned owner-only home; `--output` modes clear their own
  outputs at startup; `AGENTS.md` joined the review-instruction globs.
- project-management: rewritten ground-up (v3) — the TPM files only what
  passes a creation bar and burns down more than it creates; audits headline
  `created N / closed M` and the approval gate is two questions.
- catalog: every skill and agent reduced to contracts, commands and
  non-derivable knowledge (~19,000 → ~8,900 markdown lines), with `decider`
  and `deep-research` hardened in the same waves (breaking: the `iced-shadcn`
  and `html-artifact` skills and the `vanillagreen-themes` pack are removed).
- docs/settings: cross-repo guidance cut to the contracts; the label taxonomy
  states the one-way GitHub → Linear creation sync; settings examples state
  rules, and a parity test fails the suite on skill/root template drift.
- repo/ci: `CHANGELOG.md` merges with git's union driver so concurrent
  Unreleased bullets stop conflicting; `tools/validate-changed` runs CI's
  diff-scoped lanes locally; merge-queue test flakes fixed.
