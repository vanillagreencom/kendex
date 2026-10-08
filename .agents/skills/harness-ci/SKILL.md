---
name: harness-ci
description: "Load to wire, tune, or debug a repo's changed-file CI skip."
summary: "Classifies a CI diff as harness-only or docs-only, names its change class, and validates classifier-authorized skipped jobs in required-context aggregators."
license: MIT
dependencies:
  required: [orch, commit-guards, review-gate, bot-instructions]
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Harness CI

Run the classifier to decide whether CI can skip product checks. Commit `.kendex-generated.json` with the renders after `kendex refresh`. The engine writes that inventory from rendered artifacts. In-place content and carrier package source remain outside it.

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

Flags and exit codes: `harness-only --help`. Consumer setup: [README.md](README.md). Workflow shapes to copy: [references/wiring.md](references/wiring.md).

Use `--mode render-candidate` only to gate the engine installation and mirror refresh. It prints `render_candidate=true|false`, permits new head-owned paths, and grants no CI skip. `change-class` must prove render before CI skips product checks.

Use `--mode docs` for the docs-only path set that `harness-only --help` defines. It prints `docs_only=true|false`.

The shared refresh caller has no engine inventory record. The classifier owns it only when its bytes equal the template at the shared workflow version tag it pins. The proof fetches that exact public release tag into its private store. A commit pin, edited caller or unavailable release grants no caller ownership. That proof covers only the caller. Other excluded paths still require a supporting verifier. A verification refusal carrying the source refresh remedy reads `cause=source-mirror-missing verb=source operation=refresh`. The caller refreshes its sources before retrying the proof.

The render proof passes the trusted sibling `bot-instructions` package to `kendex verify --bot-instructions-from` only when `verify --help` advertises the option. Otherwise it uses the legacy verify call and ownership rules. Its checker compares bot output files through `--spec`, which reads the judged package's doctrine as data. It reports whole files only. Before applying the standard-class path exclusion, the classifier can use this proof for outputs outside the engine inventory only with a supporting verifier. A failed optional proof keeps that exclusion; a failed required render proof keeps its existing failure result.

`scripts/change-class` answers the wider question every gate, workflow and lane asks: what kind of change is this diff. It prints one of `render`, `trivial`, `micro`, `small` and `standard`, takes the same event and endpoint flags, and hands every read of a diff range to `harness-only` or to orch's branch measurement rather than deriving one, the revision the base end of the range resolves to included. `render` is proved by re-rendering: `kendex verify --json` has to report files checked and none failed. The proof passes `--at-record` beside `--base`, so each package that follows its source renders at the commit the install record names, held to its source's history and to no older than the base's record, and a render the catalog has moved past since its push is still weighed and prints one `render-stale:` line per source commit it trails; and each changed path has to be owned by a position a passing record of that run prints — a file, a tree, or keys in a shared file whose rest kendex reports unchanged since the range's base. Neither the inventory nor the install record is taken as proof of its own provenance, because the branch can rewrite both; each is owned from the record `kendex verify` prints for it, which passes only where the file is as kendex writes it. Every other surviving path answers `standard` with `cause=render-path-unowned`, and a shared file kendex cannot vouch for answers `cause=render-path-partial`. Both ownership refusals carry `measured=true`: missing ownership evidence, including `foreign=unknown`, selects standard with full checks. A required classifier read failure or a failed verifier result stays unmeasured. Consumer refresh publishes a successful `standard measured=false` reading through standard review and product CI. A failed classifier call or an absent class line stops publication. An unmeasured render permits no check skip. Deletion requirements and refusals: `change-class --help`. A changed kendex configuration file refuses every narrow class, not only `render`; the paths `trivial`, `micro` and `small` all refuse are orch's [narrow-change.conf](../orch/references/narrow-change.conf), whose ceilings are the last two classes' alone and which [micro.md](../orch/workflows/micro.md) § Escape condition 3 states in prose. That list names the files a package's risk sits in, never the package whole. In the size path, a names-only inventory change that unlists only paths the diff deletes leaves the path set the list and the subsystem rule read, under the conditions in `change-class --help`. An agent instruction file, an `instruction` line of that list (`AGENTS.md` and `SKILL.md`), that earns `trivial` or `micro` answers `small`, `cause=instruction-file`, the lowest class the default review policy gives a bot round; `item-tier` holds a Location naming one to `small` from the same lines. Every verdict also prints a `queue-only: queue_only=true|false` line on stderr, off the `queue` lines of the same list, the repository's own `HARNESS_CI_QUEUE_PATHS`, the lanes its default branch's `.github/ci-lanes.conf` marks `:queue`, which the change-class action defers off a pull request to the merge group, and the jobs its `HARNESS_CI_QUEUE_SELECTOR` command names for the merge group; `change-class --help` states when it reads `true`. `github.sh pr-merge` reads that line before it takes the admin route. Flags and settings: `change-class --help`.

Required-context aggregators call `scripts/aggregate-needs`. Pass the full `toJSON(needs)` object, the classifier job name, and each job a verdict may skip: `--skippable` beside the one `--waiver`, `--lane JOB=LANE`, whose skip the lane's own verdict in the classifier job's outputs authorizes, or both. The helper rejects a failed classifier, a failed or cancelled job, and a skipped job no verdict stood down. A workflow with several lanes declares the paths each reads in its default branch's `.github/ci-lanes.conf`, and the change-class action answers one verdict per lane: [references/wiring.md § Per-lane verdicts](references/wiring.md#per-lane-verdicts).

## This package never edits a workflow

Nothing here writes `.github/`. Wire the one step yourself, once, from [references/wiring.md](references/wiring.md). A repository under the organization standard reports the aggregate `CI` context: it copies [templates/ci.yml](templates/ci.yml) to `.github/workflows/ci.yml`, or names its own workflow's aggregate job `CI`, per [references/wiring.md § The CI context](references/wiring.md#the-ci-context).

## The rules to hold when wiring it

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.

**Keep the required-context job unconditional.** Gate the expensive lanes with a job-level `if:` off a `changes` job's output, or a step-level `if:` inside an aggregate, and let the aggregate that carries the required name run on every event.

**A job-level `if:` needs a status function.** Without one it keeps the implicit `success()` and skips the lane whenever the classifying job failed, which stands the expensive lanes down on exactly the diffs nothing classified. An aggregate accepts a `skipped` lane only after checking that the classifier ran and cleared the diff.

**A lane reading a path family beside the verdict needs more than the status function.** A dead classifying job publishes no outputs, so the family term reads empty and skips the lane on its own. Lift it behind `needs.changes.result != 'success'`, the two-gate shape in [references/wiring.md](references/wiring.md).

**A step that installs a tool for an unconditional lane stays unconditional.** A harness-only `if:` on the install, while the lane that runs the tool runs on every event, fails that lane on a harness-only diff. The tools commit-guards needs are in [commit-guards CHECKS.md § py-names](../commit-guards/CHECKS.md#py-names) and [§ secrets](../commit-guards/CHECKS.md#secrets).

## Reading a verdict

`stdout` is the selected verdict line alone; changed paths and reasons go to `stderr`; exit `2` is a wiring error that prints no verdict.

## Fail-closed

Every unprovable case answers `false`, which runs every lane ([DEVELOPMENT.md § Invariants](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/DEVELOPMENT.md#invariants)). `--no-renames` is fixed. `change-class` answers `standard` on the same terms.

**A class is never read from an author-writable field.** Not a label, not a branch name, not a pull request title, and no flag carries one: the author of the diff being judged writes all of them, so trusting one fails open on exactly the diffs that most want to pass. A caller that acts on a verdict without review runs the DEFAULT BRANCH's copy of the script against the pull request's tree, because the branch can change the script too.

**Nothing out of the judged tree runs, and nothing in it is read as configuration.** `change-class` takes its measurement settings from its own process environment, else from the `[env]` tables of `kendex.settings.toml` and `.kendex/settings.toml`, the second winning, as the commit `--base` names holds them (the pull request's base tip or a merge group's base, never the merge base), parsed and never sourced; the judged tree's settings and the private env file never reach it. It runs `kendex verify` in a private checkout with a git directory of its own, which carries no kendex arming record, so no package's declared checker runs out of the tree under judgement.

**The judged checkout is read, never written, and never weighed.** The `render` proof weighs the commit `--head` resolves to, checked out privately, whatever the judged checkout's own HEAD is and whatever uncommitted content it holds.
