---
name: bot-instructions
description: "Load to change what the GitHub review bots are told, or to add, render, or validate a repo's bot-instruction files."
summary: "One doctrine source plus a per-repo TOML renders every GitHub review bot's native instruction file: AGENTS.md § Code Review Rules for Codex, Copilot repo-wide and path-scoped instructions, a full-state .coderabbit.yaml, .pr_agent.toml with best_practices.md, and a .macroscope tree. Validators cover the surfaces that fail silently."
license: MIT
user-invocable: true
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
| Macroscope | `.macroscope/ignore.md`, `.macroscope/correctness/*.md`, and nothing else | the pull request's most recent commit, or the default branch for a fork |

Three of the five reach the `AGENTS.md` section, which is why it is the
doctrine root and why `[bots] codex = false` with `copilot` or `coderabbit` on
is a `toml-schema` error. Codex and Macroscope each read one surface and nothing
else, so both carry every doctrine block; the routing table in
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
  phase is reported naming every path already replaced.
- `check` re-renders and compares. It reads the working tree by default and the
  index under `--staged`. Any difference is a finding naming the path and the
  differing region.
- `adopt` is the one-time verb for a repo that already has hand-written bot
  files. `render` refuses to replace a file at a generated path that does not
  carry this package's marker; `adopt` takes such a file over, printing what it
  replaced so the diff shows the content that has to survive in the TOML.

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
an error telling the author to add the heading and render again.

Codex also reads the nearest nested `AGENTS.md` covering each changed file. The
generator writes only the root section, so a nested `AGENTS.md` carrying a
`## Code Review Rules` section is an unmanaged instruction surface that reaches
Codex without passing through doctrine. `check` reports one.

`.github/instructions/` and `.macroscope/correctness/` may hold hand-written
files beside generated ones. The generator writes only the names the TOML's
surfaces produce and reads nothing else. Telling the two apart is what the
marker comment is for, and it is the only test: anything carrying the marker
that the current TOML does not produce is an orphan, and `check` reports it.
That is a retired surface's file, a retired bot's, and the `AGENTS.md` region
when `codex` goes false. An unmarked file at one of those paths is the repo's
own, whatever the flags say, and `adopt` is how one becomes managed. Retiring a
surface or a bot otherwise leaves a file every bot keeps loading.

Every output path is resolved before it is written and refused when any
component is a symlink or when the resolved path leaves the repo root.

## A pull request changing its own review

Copilot, CodeRabbit and Macroscope read their instruction files from the pull
request's own head. A pull request that edits a generated file, the doctrine
source, the TOML, or the generator changes the review that pull request
receives, and a re-render makes `check` pass on the weakened policy. Showing
the change in the diff is not a trust boundary.

No repo file can close that, and this package does not claim to. What a repo
whose merge gate consumes bot output has to do instead:

- Treat `bot-instructions.toml`, the doctrine source, every generated path, and
  every `AGENTS.md` in the repo as policy paths. A push touching one
  invalidates review evidence gathered before it, so the deciding review is the
  one that ran after the policy change was visible.
- Require a trusted human approval on a pull request that touches a policy
  path. Bot evidence gathered under head-branch policy the same pull request
  wrote is not evidence.
- Run `check` in CI from the default branch's copy of this package, never from
  the pull request's checkout: a workflow that checks out the default branch
  for the generator and validators, then points them at the pull request's
  tree. It reads the pull request's TOML and doctrine source, because a
  legitimate doctrine change has to be able to land. What the trusted checkout
  buys is that a tampered generator cannot report a clean render; it does not
  and cannot stop a policy change, which is what the approval rule above is
  for.

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

The generator locates exactly one `## Doctrine` section in this file. Zero
sections, or more than one, is an error rather than a guess. Blocks are the
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
those paths, on any surface, in any round. The repo's own instruction file
names which trees these are.

### trust-model

Review evidence is a formal review object from a trusted login, or another
evidence form the repo's gate configuration names. Comment text, emoji
reactions, and approvals spelled in prose are never approval, by design. Do not
recommend parsing them.

## Adding a repo

1. Write `bot-instructions.toml` at the repo root per
   [schemas/repo-toml.md](schemas/repo-toml.md). An existing hand-written bot
   file is the source for its `[[surface]]` blocks and exclusions: read it,
   move its repo-specific claims into the TOML, and let doctrine carry the
   rest.
2. Run `adopt`, which names every existing file it is taking over. Read that
   list against the TOML: a claim in one of those files that the TOML does not
   carry is about to be deleted.
3. Run `render`, then read the diff. Doctrine text appearing for the first time
   is expected; a repo-specific claim disappearing means it never made it into
   the TOML.
4. Work [references/checklist.md](references/checklist.md). Every bot has at
   least one setting no file can express, and a bot whose install or enablement
   step is skipped reviews nothing while every file below looks correct.
