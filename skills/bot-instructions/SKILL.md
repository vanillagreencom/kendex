---
name: bot-instructions
description: "Load to read the bot-instructions specification: the shared review doctrine, the per-repo TOML schema, the per-surface render rules, and the validators. The generator these describe is not built yet."
summary: "Specification for a package that renders every GitHub review bot's native instruction file from one doctrine source plus a per-repo TOML: AGENTS.md § Code Review Rules for Codex, Copilot repo-wide and path-scoped instructions, a full-state .coderabbit.yaml, .pr_agent.toml with best_practices.md, and a .macroscope tree, with validators for the surfaces that fail silently. The generator is not built yet."
license: MIT
user-invocable: false
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "0.1.0"
tags: [review]
---

# Bot Instructions

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

> **This package is a specification, not working software.** There is no
> `scripts/` directory and none of the verbs below exist yet. Every command,
> validator and render rule here is the contract the generator will be built
> against. Until it lands, loading this skill tells you what the files should
> say; it does not give you anything to run, which is why the package is not
> user-invocable.

Five review bots read four incompatible instruction files, and no two of them
agree on where guidance goes. Written by hand, one repo's doctrine drifts from
the next repo's, and an exclusion list falls behind the tree it excludes
without anything saying so.

This package holds the doctrine once. A per-repo TOML says what is true about
that repo, and the generator writes each bot's native file from the pair. The
rendered files are outputs: a hand edit to one is erased by the next render,
and the drift validator reds before that happens.

## What reads what

| Bot | Reads | Reads from |
|-----|-------|-----------|
| Codex | `AGENTS.md` § Code Review Rules, root plus nearest nested | undocumented |
| Copilot code review | `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `AGENTS.md` | the pull request head |
| CodeRabbit | `.coderabbit.yaml`, whole-file, beneath any organization or workspace global override, plus `AGENTS.md` through `knowledge_base.code_guidelines.filePatterns` | the pull request head |
| Qodo | `.pr_agent.toml`, `best_practices.md`, `REVIEW.md` | the default branch root |
| Macroscope | `.macroscope/ignore.md`, `.macroscope/correctness/*.md`, plus `.macroscope/check-run-agents/**` and `.macroscope/approvability.md`, which this package never writes | the pull request's most recent commit, or the default branch for a fork |

Three of the five reach the `AGENTS.md` section — Codex, Copilot and
CodeRabbit — which is why it is the doctrine root and why `[bots] codex = false`
with `copilot` or `coderabbit` on is a `toml-schema` error. Qodo and Macroscope
are the two that do not.

A separate count decides which surfaces carry every block: Codex and Macroscope
each read exactly one surface this package writes, so a block left out of that
one reaches the bot nowhere. That is why `AGENTS.md` and
`.macroscope/correctness/doctrine.md` carry all eight. The routing table in
[schemas/renders.md](schemas/renders.md) is where that lives, one row per block
and one column per destination.

Verified caps, enum values and read semantics are in
[references/limits.md](references/limits.md), each with the vendor page that
states it, and each claim resting on fleet experience rather than a vendor page
is labeled there as such. Nothing in the generator holds a limit that file does
not carry.

## The pieces

```
doctrine (§ Doctrine below)     the rules that must reach two or more bots
bot-instructions.toml           one per repo, at the repo root
  ├─ [repo]                     what this repo is, in the bots' own words
  ├─ [bots]                     which bot capabilities are live here
  ├─ [cadence]                  when each bot re-reviews
  ├─ [exclusions]               what is not this repo's code to fix
  ├─ [[surface]]                a path set and what a reviewer must know there
  └─ [doctrine]                 per-repo additions to a doctrine block
        │
        ▼  render
AGENTS.md § Code Review Rules   .coderabbit.yaml
.github/copilot-instructions.md .pr_agent.toml + best_practices.md
.github/instructions/*.md       .macroscope/
```

A `[[surface]]` is authored once and reaches three bots: a Copilot
`.instructions.md` file scoped by `applyTo`, a CodeRabbit `path_instructions`
entry, and a Macroscope `correctness/` file scoped by `include`. Qodo has no
per-path instruction mechanism, so surface text reaches it through
`best_practices.md`.

Authored once does not mean matched identically. Only Macroscope has a
subtraction key, so `exclude_globs` is real scoping there and prose everywhere
else. Where exact scoping matters, narrow `globs` rather than relying on
`exclude_globs`. [schemas/renders.md](schemas/renders.md) states which
mechanism each surface actually gets.

The per-file render rules, including every escaping and ordering decision, are
in [schemas/renders.md](schemas/renders.md). The TOML's keys and their types
are in [schemas/repo-toml.md](schemas/repo-toml.md). What each validator
rejects, and the silent failure it exists to catch, is in
[schemas/validators.md](schemas/validators.md).

## Commands

The generator offers three verbs.

- `render` writes every enabled surface from doctrine plus the repo TOML, after
  validating what it built. It builds and validates in a scratch tree first, so
  a validator failure leaves the repo untouched; a failure during the write
  phase is reported naming every path already replaced, each of which holds
  either its old bytes or its new ones — every replacement is atomic, so an
  interrupt never leaves a truncated file. `AGENTS.md` is the exception to
  scratch-then-replace, because it is the one output whose non-owned bytes
  belong to the repo: what the build produces is the region's body, and the
  write splices it into the file's bytes read at write time.
  The validators that judge repository state rather than emitted bytes read the
  repo, before the write, so a render that would orphan a file fails instead of
  reporting a clean pass and then orphaning it. `schemas/validators.md` § Where
  these run is the split.
- `check` re-renders and compares. It reads the working tree by default; under
  `--staged` it reads the index, for every render input as well as the outputs,
  so a pre-commit lane judges one coherent staged state. Any difference is a
  finding naming the path and the differing region.
- `adopt` is the one-time verb for a repo that already has hand-written bot
  files. `render` refuses to replace a file at a generated path that does not
  carry this package's marker, and it reads that marker on the file it has
  opened to replace rather than on some prior pass over the repo, so nothing
  can slip into the gap; `adopt` takes such a file over, printing what it
  replaced so the diff shows the content that has to survive in the TOML. It
  takes a region over the same way, which is how a hand-added `AGENTS.md`
  heading becomes managed.

There is no install-time placement step, no overwrite prompt, and no merge of
hand edits back into doctrine. A generated file is either byte-identical to its
render or a `check` finding.

A render holds a lock file for its duration and a second concurrent render
refuses, because two renders interleaving their writes produce a tree neither
validated.

## Rendering into a file this package does not own

`AGENTS.md` is the repo's own instruction file, written for working agents. The
generator owns exactly the slice from the `## Code Review Rules` heading to the
next heading at that level or above, and never the rest, and it opens that slice
with the marker so the region is as identifiable as a whole file. It never
creates `AGENTS.md` and never adds the heading: a repo without that section is
an error telling the author to add the heading, set `[bots] codex`, `adopt`,
then render. The flag comes before the `adopt` because `adopt` takes a region
over only for a capability that is on, and the `adopt` is not optional because a
hand-added heading is an unmarked region at a generated path, which is exactly
what `render` refuses.

Codex also reads the nearest nested `AGENTS.md` covering each changed file. The
generator writes only the root section, so a nested `AGENTS.md` carrying a
`## Code Review Rules` section is an unmanaged instruction surface that reaches
Codex without passing through doctrine. `check` reports one.

`.github/instructions/` and `.macroscope/correctness/` may hold hand-written
files beside generated ones. The generator writes only the names the TOML's
surfaces produce and reads nothing else. Telling the two apart is what the
marker comment is for, and it is the only test: anything carrying the marker
that the current TOML does not produce is an orphan. That is a retired surface's
file, a retired bot's, and the `AGENTS.md` region when `codex` goes false. An
unmarked file at one of those paths is the repo's own, whatever the flags say,
and `adopt` is how one becomes managed.

**Retiring one is delete-then-render, in that order**, because `render` fails on
an orphan rather than creating one. `check` catches a retirement that skipped
the render; it is not the normal path. `validators.md` § `orphan` carries the
order and what deleting the `AGENTS.md` region means.

**Every open is contained, and the rule is about opens rather than about
outputs.** Resolving a path, checking it, then opening it proves the property
about the name and not about the file the open lands on, so the property is held
at the open. Two halves, and both are needed:

- **No component may redirect.** Walking from a repo-root descriptor, each
  component is opened relative to the previous one with directory and no-follow
  flags. A symlink anywhere in the path fails, not only a final one: with
  `.github/instructions` a symlink out of the tree, refusing only the last
  component creates or truncates a file outside the repo root and any check
  after that fires too late. Containment is then a property of how the
  descriptor was reached rather than something re-derived from the opened file,
  which is what makes it checkable at all — re-deriving a path from a descriptor
  needs a different mechanism on each platform this repo targets.
- **Every open, not every write.** `render` writes, but `check` mostly reads:
  `drift` opens each path the TOML produces, `orphan` walks
  `.github/instructions/**` and `.macroscope/correctness/**` testing each file
  for the marker, `agents-section` walks the repo for nested `AGENTS.md`, and
  `adopt` opens the markdown files the ones it takes over point at. Those sets
  are named by the tree under judgment. A symlink at any of those paths is
  followed by a trusted reader, and its bytes are quoted into a `check` finding
  in a CI log — a disclosure route no write-side rule covers, because nothing is
  written.

A path that fails is a finding naming the path, and a `check` finding never
quotes a region out of a file that failed the open: what gets reported is the
containment failure, not the contents.

This repo's own convention is the precedent for the no-follow half — it opens
without following and re-checks the opened file's type rather than the name. The
walk from a root descriptor is the part it does not have.

## Every rendered config excludes the render trees

**A render-only diff opens no bot rounds.** That is the requirement, and it is
what the exclusion set is for: a tracked tree this repo renders from an upstream
package is not its code, so a finding on one costs a round nobody here can
spend. Every config this package renders excludes those trees, and a surface
with no file-based review exclusion carries the paths as prose, so the
instruction names something rather than gesturing at it.

**Two of the five subtract for real; three are asked.** CodeRabbit's
`path_filters` and Macroscope's `ignore.md` remove the files from review. Codex,
Copilot and Qodo receive the paths as prose, and **a bot asked to skip a path
may still comment on it** — none of the three has a file-based review exclusion
this package can reach. Naming the paths there makes the instruction actionable;
it is not enforcement. `schemas/renders.md` § Doctrine routing says which
surface gets which mechanism, and `references/checklist.md` says where
enforcement for the three has to come from instead.

## A pull request changing its own review

Copilot, CodeRabbit and Macroscope read their instruction files from the pull
request's own head. A pull request that edits a generated file, the doctrine
source, the TOML, or the generator changes the review that pull request
receives, and a re-render makes `check` pass on the weakened policy. Showing
the change in the diff is not a trust boundary.

No repo file can close that, and this package does not claim to. What a repo
whose merge gate consumes bot output has to do instead:

- Treat every path in the policy set below as a policy path. A push touching one
  invalidates review evidence gathered before it, so the deciding review is the
  one that ran after the policy change was visible.
- Require a trusted human approval on a pull request that touches a policy
  path. Bot evidence gathered under head-branch policy the same pull request
  wrote is not evidence.
- Run `check` in CI from the default branch's copy of this package, never from
  the pull request's checkout: a workflow that checks out the default branch
  for the generator and validators, then points them at the pull request's
  tree, passing `--spec` for the package copy in that tree. Inputs come
  from the tree under judgment, because a legitimate doctrine or TOML change has
  to be able to land; the trusted checkout supplies the code. What that buys is
  that a tampered generator cannot report a clean render. It does not and cannot
  stop a policy change, which is what the approval rule above is for.

**The render inputs**, which is every path a render reads to produce bytes. This
is the one statement of the set: the marker names them, `check --staged` reads
each from the index, every one is under the open rule above, and the policy set
below contains them.

- `bot-instructions.toml`.
- The spec copy's doctrine source and routing table.
- `.bot-instructions/coderabbit-schema.json`, when `[bots] coderabbit` is true.
- Both install manifests, when `[exclusions] derive_render` is true. It is a pair
  rather than one file: the root `kendex.toml` is always read, because whether
  it declares `is_source_catalog` is what decides where install state lives, and
  `kendex-local.toml` is read as well when it does. Naming only the resolved one
  would leave a staged lane reading routing bytes from the worktree and install
  state from the index, judging a state nobody is committing.
- The existing `AGENTS.md`, when `[bots] codex` is true.

What a repo-state validator walks is deliberately not in that set: `orphan`'s
sweep of `.github/instructions/**` and `.macroscope/correctness/**`, and
`agents-section`'s walk for nested `AGENTS.md`. Those enumerate paths rather
than reading a fixed input, so the marker could not name them and no render
consumes their bytes. They are covered twice over anyway — every open is under
the rule above, and a repo-state validator reads whichever tree `check`
selected, the worktree by default and the index under `--staged`, so the staged
lane still judges one coherent state. The policy set below does contain the
trees they walk.

**The policy set**, which is every path whose bytes decide what a bot is told or
whether a render validates. This list is the one statement of it; the checklist
line points here rather than repeating it, so the two cannot drift.

- Every render input above.
- This package's own installed tree: the generator and the validators, not only
  the doctrine source and routing table the render inputs already name. They
  decide whether a render validates, which is half the definition above. The
  trusted CI checkout is why an edit to them cannot fool `check` in CI — that
  lane runs the default branch's copy — but the local verbs run the head's, and
  a policy path is about what a push invalidates rather than about what one
  lane happens to read.
- Every generated path.
- Every `AGENTS.md` in the repo. Codex reads the nearest nested one, so a file
  the root render never touches still reaches it.
- Every file under `.github/instructions/`, `.macroscope/correctness/`,
  `.macroscope/check-run-agents/`, and `.macroscope/approvability.md`, marked or
  not. Copilot and Macroscope load an unmarked file from those just as readily
  as a generated one, and nothing else here judges it. The last two this package
  never writes at all, which makes them unmanaged surfaces rather than
  unmanaged files.
- Any repo-wide reviewer file the repo keeps by hand.
  `references/checklist.md` § Adding a repo says what becomes of one.

Two asymmetries are worth knowing. Macroscope reads the default branch for a
fork pull request, so a fork cannot weaken its own review the way a branch
pull request can. And an organization or workspace CodeRabbit override outranks
the repo file entirely, which is the same problem from the other side: a
setting the repo cannot see decides what the repo's file means.

## What "shared doctrine" does and does not mean

The generator reads the doctrine source from this package as installed in the
consuming repo, so a repo running an older installed copy renders older
doctrine, and both `render` and `check` pass. Nothing here compares one repo's
doctrine against another's.

What makes the staleness visible is the marker: it names this package and its
version, so a version bump re-renders every file in that repo and the diff says
which doctrine the repo is now on. A fleet-wide doctrine change is therefore an
update of this package in each repo followed by a render, and the repos that
have not done it are the ones whose marker still names the old version.

That only works if a doctrine edit ships a version bump. Nothing in a consuming
repo can check it, because a consumer sees one version and has nothing to
compare it against; the rule belongs to the repo that publishes this package,
and it is the reason the version is in the marker at all.

## Doctrine

The generator reads doctrine from a **spec copy**: a copy of this package, whose
`SKILL.md` carries this section and whose `schemas/renders.md` carries the
routing table. It defaults to the running copy, and `--spec <path>` names
another, which is what lets a trusted checkout render a tree whose doctrine has
moved. One flag for both files because they are one set: `doctrine-routing`
holds the headings here to the rows there, so reading them from different
copies would red on every legitimate doctrine change. The marker records the
version from the spec copy's frontmatter, not the running copy's, and a spec
copy with no readable version is an error — otherwise a doctrine change would
land under a stamp naming doctrine it does not carry.

The generator locates exactly one `## Doctrine` section in the doctrine source.
Zero sections, or more than one, is an error rather than a guess. Blocks are the
`###` headings inside that section, each sliced from its heading to the next
heading at that level or above, still inside the section. A repeated block id
inside the section is an error, and a heading found outside the section is not
doctrine whatever it is named. That rule is what makes the parse safe against a
project-instructions block a harness injected after the frontmatter.

Block ids are frozen: `schemas/renders.md` names blocks by id, and a rename is
a breaking change to every render.

A block reaches a surface as prose. Nothing in a block may carry markdown a
YAML or TOML scalar cannot hold verbatim, and nothing in it names a repo, a
path, or an issue. Repo-specific text belongs in the TOML.

### scope

Raise a defect in the lines this pull request changed, or one those lines
directly break. Correctness, security, data loss, and a fail-open path in gate,
guard, or CI code are the classes that matter. Anything outside the diff and
its direct blast radius is out of scope, including a scope observation about a
file the pull request body already names as deliberate.

### rounds

Surface everything you have about the current diff in one round. A finding held
back for the next round costs a full re-review cycle, and these pull requests
are pushed at agent speed. One comment per root cause, naming every affected
site in that comment, rather than one comment per site.

### severity

Mark a finding blocking only if you would stop a colleague's merge for it.
Everything else is a suggestion. Batch suggestions, and omit them on a
re-review round whose diff is a one-line fix. Naming a finding's severity
honestly is worth more than raising it: a confident wrong finding costs more
than a hedged one.

### no-preferences

Style, wording, naming, and comment phrasing are not findings here. Neither is
speculative hardening on a path that already fails closed. Formatting and lint
belong to CI. Ask for test coverage only where the diff changes behavior no
test exercises, and then say which behavior, in one comment.

### declined

A finding class answered on this pull request with a stated decline is settled.
Do not raise it again on a later round unless the relevant code changed since.
The same holds for a class the repo has recorded as an accepted trade-off in
its own instruction files: read those before asserting a rule.

### reply-contract

Author replies are `Fixed in <sha>`, `Declined: <reason>`, or
`Tracked: <issue>`. A decline names the passing state or the false premise it
disproves, and a label alone is not a reason. A merge gate reading these
replies rejects a tracking claim naming no issue, and a decline whose reason is
nothing but a label it knows.

### render-out-of-scope

A tracked tree this repo renders from an upstream package is not this repo's
code. A review comment on it cannot be acted on here: the fix lands upstream
and arrives by re-render, and an in-repo edit is erased. Report nothing on
those paths, on any surface, in any round. The paths themselves follow this
block wherever a surface has no other way to receive them.

### trust-model

Review evidence is a formal review object from a trusted login, or another
evidence form the repo's gate configuration names. Comment text, emoji
reactions, and approvals spelled in prose are never approval, by design. Do not
recommend parsing them.

## Adding a repo

The procedure is [references/checklist.md](references/checklist.md) § Adding a
repo, beside the settings work it runs into, and it derives its order from
`toml-schema`'s cross-flag clauses, `adopt`'s rule and `agents-section`'s
ungated nested-`AGENTS.md` clause rather than restating one. The shape worth
knowing before you start: nothing that depends on a flag is written before the
flag, so a capability's surfaces, `adopt` and `render` all happen in the pass
that turns it on — and the one constraint no flag carries, a nested
`## Code Review Rules` section, is cleared before the first render of all.
