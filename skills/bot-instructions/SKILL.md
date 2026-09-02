---
name: bot-instructions
description: "Load to render, check or adopt a repo's GitHub review-bot instruction files from the shared doctrine plus its bot-instructions.toml, or to read the doctrine, the TOML schema, the render rules and the validators."
summary: "Renders every GitHub review bot's native instruction file from one doctrine source plus a per-repo TOML: AGENTS.md § Code Review Rules for Codex, Copilot repo-wide and path-scoped instructions, a full-state .coderabbit.yaml, .pr_agent.toml with best_practices.md, and a .macroscope tree, with validators for the surfaces that fail silently."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

# Bot Instructions

```bash
.agents/skills/bot-instructions/scripts/bot-instructions render   # write every enabled surface
.agents/skills/bot-instructions/scripts/bot-instructions check    # re-render and compare
.agents/skills/bot-instructions/scripts/bot-instructions adopt    # take hand-written files over
```

Flags: `--repo`, `--spec`, `--staged`, `--dry-run`; `bot-instructions --help`.
Python 3.11+.

## What reads what

| Bot | Reads | Reads from |
|-----|-------|-----------|
| Codex | `AGENTS.md` § Code Review Rules, root plus nearest nested | undocumented |
| Copilot code review | `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `AGENTS.md` | the pull request head |
| CodeRabbit | `.coderabbit.yaml`, whole-file, beneath any organization or workspace global override, plus `AGENTS.md` through `knowledge_base.code_guidelines.filePatterns` | the pull request head |
| Qodo | `.pr_agent.toml`, `best_practices.md`, `REVIEW.md` | the default branch root |
| Macroscope | `.macroscope/ignore.md`, `.macroscope/correctness/*.md`, plus `.macroscope/check-run-agents/**` and `.macroscope/approvability.md`, which this package never writes | the pull request's most recent commit, or the default branch for a fork |

Routing per block and surface: [schemas/renders.md](schemas/renders.md) § Doctrine routing. Vendor caps: [references/limits.md](references/limits.md).

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
A `[[surface]]` reaches Copilot, CodeRabbit and Macroscope, plus Qodo through `best_practices.md` when `[bots] qodo_best_practices` is on. Only Macroscope honors `exclude_globs`, so narrow `globs` where scoping matters. Keys: [schemas/repo-toml.md](schemas/repo-toml.md). Validators: [schemas/validators.md](schemas/validators.md).

- `render` writes every enabled surface after validating it.
- `check` re-renders and diffs, reading the index under `--staged`.
- `adopt` takes a hand-written file or `AGENTS.md` region under management once.

The generator owns only the `AGENTS.md` § Code Review Rules region and never creates the file. A repo without the heading adds it, sets `[bots] codex`, runs `adopt`, then `render`. A tracked nested `AGENTS.md` carrying that heading is a `check` finding. Retire a surface with delete, then `render`. `render` replaces only a file whose canonical marker is present; `adopt` is the way in. Details: [schemas/renders.md](schemas/renders.md) § Common rules.

## Every rendered config excludes the render trees
A repo enables `[exclusions] derive_render` or lists every render tree in `[[exclusions.path]]`. Set construction: [schemas/repo-toml.md](schemas/repo-toml.md) § `[exclusions]`. Placement and enforcement: [schemas/renders.md](schemas/renders.md) § Doctrine routing.
## A pull request changing its own review

- Treat every policy path below as invalidating prior review evidence.
- Require trusted human approval on a pull request that touches a policy path.
- Run `check` in CI from the default branch copy, with `--spec` naming the pull request tree's package copy.

## The render inputs
- `bot-instructions.toml`.
- The spec copy's doctrine source and routing table.
- `.bot-instructions/coderabbit-schema.json` when CodeRabbit is on.
- `kendex.toml`, plus `kendex-local.toml` for a source catalog, when render exclusions are derived.
- The existing `AGENTS.md` when Codex is on.

Policy set:
- Every render input above.
- This package's installed tree.
- Every generated path.
- Every `AGENTS.md` in the repo.
- Every file under `.github/instructions/`, `.macroscope/correctness/`, `.macroscope/check-run-agents/`, and `.macroscope/approvability.md`.
- Any repo-wide reviewer file kept by hand.

Version and marker semantics: [schemas/renders.md](schemas/renders.md) § Common rules.

## Doctrine

The generator reads exactly one `## Doctrine` section from the spec copy named by `--spec`, or the running copy by default, ending at the next level-one or level-two heading.
Each `###` heading inside it is a frozen block id; a repeated id is an error.
A section with no blocks or a block with no text is an error.
A block holds no repo, path, issue, or markdown that a YAML or TOML scalar cannot carry verbatim; repo text goes in `bot-instructions.toml`.

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

[references/checklist.md](references/checklist.md) § Adding a repo.
