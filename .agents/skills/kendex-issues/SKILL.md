---
name: kendex-issues
description: "Load to monitor kendex's issue queue continuously or to run one fix-and-propagate cycle."
summary: "Stewards the kendex issue queue on a self-paced loop: watches open PRs, polls Linear, triages, fixes defects through orch, merges, propagates with kendex refresh."
---

# kendex Issue Steward

watch → poll → triage → fix → merge → propagate → reschedule. One cycle per
turn.

| Concern | Owning skill |
|---|---|
| Fix cycle (prepare → delegate → review → submit → merge) | **orch** |
| PR threads, replies, reviews, merges, CI logs | **github** |
| Watching open PRs | **review-gate** `pr-watch.sh` |
| Linear reads and writes | **linear** |

Hand-rolled PR mechanics (raw `gh api` where a `github.sh` command exists)
are a defect.

## Loop (one turn)

1. **PR watch** — `GH_REPO=vanillagreencom/kendex .agents/skills/review-gate/scripts/pr-watch.sh`.
   Silence + exit 0 = nothing needs you. Attention lines → act through the
   github skill. After a gate-green, also check `isInMergeQueue` +
   `autoMergeRequest` (GraphQL). Queue ejection is silent: re-arm once; a
   second ejection is a flaky required suite — quarantine, never re-arm loops.
2. **Poll Linear** — `linear.sh sync --reconcile`, then
   `linear.sh cache issues list --state "Triage,Backlog,Todo,In Progress" --max`.
   Linear is the complete queue (GitHub→Linear sync is one-way); Triage holds
   the GitHub-synced arrivals. Cross-check `gh issue list --repo vanillagreencom/kendex --state open`:
   an open GH issue whose Linear mirror is Done is residue — close it naming
   the PR; one with no mirror means the sync broke — triage it from GitHub
   and say so. Nothing on either surface → reschedule.
3. **Triage** each issue (below); run the fix cycle for each valid defect.
   Mutate on the issue's home surface: GH-mirrored issues (Linear body links
   the GH issue) are closed/commented on GitHub; Linear-native ones through
   the linear skill. PR body carries `Closes KEN-<n>` plus `Closes #<n>` when
   a mirror exists.
4. After any merge, **propagate**.
5. **Reschedule** (Cadence). Stop only if the user asked.

## Triage

- **Duplicate** → close, name the canonical issue.
- **Not a kendex asset** → ownership is the asset's SKILL.md frontmatter
  (`source: kendex`), never its install path. Close with the reason; repost
  project-local items to the owning repo, cross-link, notify that repo's
  overseer (tmux window 1 of `memsira`, `drovr`, `hyprtrade`). Never fix a
  consuming repo's defect.
- **Edge case (<1% of users), contrived layout, race between two local
  processes, or reviewer hypothetical with no report** → cancel with the
  reason. The bar for a kendex issue is a reported symptom.
- **Over-built proposal** → cancel; state the simpler approach in one line
  if one exists.
- **Genuine kendex defect** (skills/, agents/, hooks/, pi-extensions/,
  crates/, ui/) → fix cycle.
- **Unfindable reference** → `git log -S '<name>' --all` first. A name that
  never existed is a typo: close with the evidence; never ship a shim.
- **Empty body** → ask for the concrete repro; leave open.

## Fix cycle — load orch

orch owns every step. kendex-specific parameters:

- **Delegate to**: `generalist` (shell/docs/skills), `rust` (crates/),
  `iced` (iced-rs). Tests required; relevant suite green
  (`bash skills/orch/tests/run-all.sh`, per-skill `tests/*.sh`, `cargo test --workspace`).
- **Scope is the reported symptom** (dev skill § Engineering Rules: its two
  exceptions — mechanical enablers ride, an armed defect is in scope). Expect
  the fix to be about the size of its first commit.
- **Fix direction**: determinism and tooling first — a deletion, a
  short-circuit, or a script; added prose last. Skills are instructions,
  not explanations; `tools/guard` refuses history and reasons in them.
- **Size ratchet**: split at a seam. `RATCHET_RAISE=1` only when the added
  lines are the fix itself and no seam exists — never for tests, docs,
  comments, or lines a review round asked for; the frozen classes (markdown
  and tests) refuse a raise whatever it says.
- **Review must converge** (orch SKILL.md): a recurring defect class is
  fixed at its source, never per comment. A round that is only scope,
  test-coverage, or wording asks ends the review: reply, resolve, push
  nothing, merge through the gate. Replies are `Fixed in <sha>`,
  `Declined: <reason>`, or `Tracked: KEN-<n>` (issue created first — the
  gate rejects a tracking claim naming no issue). Never `--admin`.
- **Review the diff yourself** before submit — the actual root cause, not a
  plausible one. A stalled delegate: inspect its worktree, nudge once.
- Findings and coupled defects disposition per orch
  `references/finding-disposition.md` — the excluded classes ahead of the
  defect fork, one reply form per thread.
- Disjoint files → parallel; same file → sequence or bundle.
- A required check that cannot be rerun gets a fresh head
  (`commit --amend --no-edit` + `push --force-with-lease`, never-shared
  heads only); never a merge past red.

## Propagate

Only from a change **merged on `origin/main`**. Batch: if open items would
force another re-vendor soon, hold and run one train; an immediate train is
for a fail-open defect in a consumer gate or an owner ask.

1. `git checkout main && git pull --ff-only`; confirm the source consumers
   read sits at the `origin/main` tip containing the merge.
2. Skill/agent/hook changes → `kendex refresh` (all scopes, never
   `--scope project`; Pi packages are global) + `kendex verify` in each
   consumer. CLI-only changes → binary rebuild, no skill refresh.
3. Consumer commits: `git check-ignore -q <path>` first (ignored = nothing to
   commit). Stage kendex paths only, never `-A`; revert no-op
   `.kendex-refreshed` and template-default churn. Branch → PR →
   `gh pr merge --auto`. Reply to and resolve bot threads. Confirm each push
   landed and carries only kendex files. While propagation PRs are open,
   `GH_REPO=vanillagreencom/<repo> pr-watch.sh --heal` each cycle.
4. New skills do not propagate by refresh: `kendex add --skill <name> -y`
   per consumer, commit its `kendex.toml` entry through that repo's queue.
5. Bot findings on propagation PRs: a real defect in vendored content is
   fixed upstream first (issue → fix → merge → refresh on the branch →
   resolve citing the fix). Nits on the PR's own payload: fix on the branch.
6. Capability changes consumers must wire into CI/branch protection: ship
   the spec in the owning skill, coordinate repo-side through each overseer,
   verify on each consumer's `origin/main`. Security-relevant capabilities
   need the user's sign-off first.

### This skill's home

Source: `.agents/skills/kendex-issues/SKILL.md` in the kendex checkout — the
real directory, declared `source = "in-place"` and installed project-scoped
only. `git rev-parse --show-toplevel` prints that checkout's root from anywhere
inside it. Edit it there; the per-harness links already point at it. Then
run `kendex apply` from the root so the install record matches the edit;
until you do, `kendex verify` reports the skill as changed since install.
A `~/.agents/skills/kendex-issues` link is a collision — delete it.

## Guardrails

- Never pipe a state-changing or guard command through `tail`/`head`/`grep`
  in a `&&` chain. Run bare, read the result, then trim. Read `worktree
  create`'s full output before entering it; an ownership refusal means
  another session owns the work.
- **Ownership.** Before a fix cycle, check for a remote branch, open PR, or
  foreign worktree for the issue. Active peer → hands off. A PR with
  unresolved threads and no pushes or replies for ~2 h whose session is idle
  is abandoned: take it over, answer every thread, note the takeover.
- **Consumer boundary.** The only write lane into consumers is kendex
  propagation plus hygiene on those PRs. Coordinate everything else over
  tmux; verify delivery with capture-pane after ~5 s; read a composer's full
  content before pressing Enter.
- **Branch safety.** Never switch or commit on a checkout mid-work; use a
  worktree off `origin/main`. Never `git stash` in a shared checkout.
- **Scoped commits, verified pushes.** Inspect diffs, `kendex verify`,
  confirm it landed.
- **Box load poisons suites.** A red suite under load: check uptime, rerun
  in isolation, A/B against clean HEAD.
- **Clean up** merged worktrees and stale branches; keep local and remote
  main in sync.

## Cadence

Widen toward ~60 min when quiet; tighten toward ~15–20 min after a new
issue or a burst.
