---
name: bot-instructions
description: "Load to render, check, or adopt a repo's GitHub review-bot instruction files from the shared doctrine and its effective manifest."
summary: "Renders every GitHub review bot's native instruction file from one doctrine source plus the [bot-instructions] manifest table, with validators for the surfaces that fail silently."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.3.0"
tags: [review]
repo-effects:
  summary: "Renders the enabled review-bot instruction files, the pointed code-review file and the owned Code Review Rules region in this repository."
  writes:
    - ".github/copilot-instructions.md"
    - ".github/instructions/"
    - ".coderabbit.yaml"
    - ".pr_agent.toml"
    - "best_practices.md"
    - "REVIEW.md"
    - ".macroscope/"
    - "AGENTS.md"
  installer: "scripts/bot-instructions render"
  uninstaller: "scripts/bot-instructions retire"
  checker: "scripts/bot-instructions check"
  removal: "Delete each generated surface and the pointed code-review file first, remove the owned Code Review Rules body but keep its heading, disable its [bot-instructions.bots] flag, render, then remove the package."
  notes:
    - "Only surfaces enabled in the effective [bot-instructions] manifest are written."
    - "The review doctrine is written to [bot-instructions.repo] code_review_path, which defaults to .github/instructions/code-review.md and is refused outside that directory, so every path this package writes is one of those listed above."
---

# Bot Instructions

```bash
.agents/skills/bot-instructions/scripts/bot-instructions render   # write every enabled surface
.agents/skills/bot-instructions/scripts/bot-instructions check    # re-render and compare
.agents/skills/bot-instructions/scripts/bot-instructions adopt    # take hand-written files over
.agents/skills/bot-instructions/scripts/bot-instructions retire   # revoke kendex automatic rendering on removal
```

Flags: `--repo`, `--spec`, `--staged`, `--dry-run`; `bot-instructions --help`. Python 3.11+.

Exit codes: 0 clean, 1 findings, 2 could not complete. A pre-commit lane blocks on both nonzero codes; the `commit-guards` chain runs `check --staged` itself where this package is installed.

## What reads what

| Bot | Reads | Reads from |
|-----|-------|-----------|
| Codex | `AGENTS.md` § Code Review Rules, root plus nearest nested | undocumented |
| Copilot code review | `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `AGENTS.md` | the pull request head |
| CodeRabbit | `.coderabbit.yaml`, whole-file, beneath any organization or workspace global override, plus the `knowledge_base.code_guidelines.filePatterns` files | the pull request head |
| Qodo | `.pr_agent.toml`, `best_practices.md`, `REVIEW.md` | the default branch root |
| Macroscope | `.macroscope/ignore.md`, `.macroscope/correctness/*.md`, plus `.macroscope/check-run-agents/**` and `.macroscope/approvability.md`, which this package never writes | the pull request's most recent commit, or the default branch for a fork |

Codex and Copilot reach the doctrine by following a pointer rather than by reading it in place. The `AGENTS.md` region is one directive line naming the pointed file, and `.github/copilot-instructions.md` carries the same pointer; CodeRabbit follows a real file reference. No block is restated to those three anywhere else, except `render-out-of-scope` in `.coderabbit.yaml`'s catch-all entry, where it is doing scoping work — [schemas/renders.md](schemas/renders.md) § Doctrine routing note (a).

Routing per block and surface: [schemas/renders.md](schemas/renders.md) § Doctrine routing. Vendor caps: [references/limits.md](references/limits.md).

## The pieces

The effective manifest holds `[bot-instructions]`. Its child tables configure bots, repo context, cadence, exclusions, path instructions and doctrine overrides. The generator writes the enabled bots' native files. Table selection and precedence: [schemas/repo-toml.md](schemas/repo-toml.md).

A `[[bot-instructions.surface]]` reaches Copilot, CodeRabbit and Macroscope, plus Qodo through `best_practices.md` when `[bot-instructions.bots] qodo_best_practices` is on. Only Macroscope honors `exclude_globs`, so narrow `globs` where scoping matters. The spec copy's own surfaces, § Default surfaces, reach the same routes in every repo with no manifest entry. Keys: [schemas/repo-toml.md](schemas/repo-toml.md). Validators: [schemas/validators.md](schemas/validators.md).

- `render` writes every enabled surface after validating it.
- `check` re-renders and diffs, reading the index under `--staged`.
- `adopt` takes a hand-written file or `AGENTS.md` region under management once.
- `retire` lets kendex revoke automatic rendering when it removes the package. It leaves generated files unchanged.

The generator owns only the `AGENTS.md` § Code Review Rules region and never creates the file. A repo without the heading adds it, sets `[bot-instructions.bots] codex`, runs `adopt`, then `render`. A tracked nested `AGENTS.md` carrying that heading is a `check` finding. Retire a surface with delete, then `render`. `render` replaces only a file whose canonical marker is present; `adopt` is the way in. Details: [schemas/renders.md](schemas/renders.md) § Common rules.

## The doctrine lives in one file per repo

`[bot-instructions.bots] codex` writes the complete doctrine to `[bot-instructions.repo] code_review_path`, which defaults to `.github/instructions/code-review.md`, and writes the `AGENTS.md` owned region as one directive line naming it. A longer region is a finding: `adopt` reports it under `agents-region` and still writes the marker, `check` reports it under `drift`, and `render` replaces it. A repo migrates by rendering. Body and bounds: [schemas/renders.md](schemas/renders.md) § `code-review.md`.

**No vendor page documents a bot following an in-file reference.** CodeRabbit's `code_guidelines.filePatterns` is a real load, so its doctrine is not at issue; Codex and Copilot reach the pointed file only by opening what the directive names, and a bot that does not reviews with no repo rules at all. A repo enabling `codex` renders a canary to find out — one harmless rule that is exclusive among the files the bot under test reads, so its appearance in a comment proves the comment was written against the pointed file. A `[bot-instructions.doctrine.append]` gives that exclusivity for Codex and Copilot, which read no other file carrying doctrine; it is not exclusive in general, since an append reaches every destination its block routes to, Qodo's and Macroscope's included. [references/limits.md](references/limits.md) § GitHub Copilot code review carries the evidence and the failure mode.

## Every rendered config excludes the render trees

A repo enables `[bot-instructions.exclusions] derive_render` or lists every render tree in `[[bot-instructions.exclusions.path]]`. Set construction: [schemas/repo-toml.md](schemas/repo-toml.md) § `[bot-instructions.exclusions]`. Placement and enforcement: [schemas/renders.md](schemas/renders.md) § Doctrine routing.

## A pull request changing its own review

- Treat every policy path below as invalidating prior review evidence.
- Require trusted human approval on a pull request that touches a policy path.
- Run `check` in CI from the default branch's package copy when the two copies are byte-identical, with `--spec` naming the pull request tree's copy; when they differ, the pull request upgrades the package and the default-branch checker cannot reproduce the candidate's render, so run the candidate's copy and print a warning naming both versions. The review gate's policy path (`REVIEW_GATE_CARRY_FORWARD_EXCLUDE` naming `.agents/skills/bot-instructions/*`) is what holds the upgrade honest: a push touching the package invalidates earlier review evidence. The package's own source repository runs the pull request's checker always.

## The render inputs

- `kendex.toml`, plus `kendex-local.toml` when the root declares `is_source_catalog = true`.
- `.kendex-generated.json` when `[bot-instructions.exclusions] derive_render` is on.
- The spec copy's doctrine source, default surfaces and routing table.
- `.bot-instructions/coderabbit-schema.json` when CodeRabbit is on.
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

Keep one `## Doctrine` section in the spec copy. `--spec` selects that copy; the default is the running package. End the section at the next level-one or level-two heading. Keep each `###` block ID unchanged and unique. Keep every block non-empty. Write text that YAML and TOML scalars can carry verbatim. Put repo names, paths, issues, and repo-specific rules in `[bot-instructions]`.

### scope

Raise a defect only in changed lines or code those lines directly break. Report correctness defects, security defects, data loss, and fail-open paths in gates, guards, or CI. Do not report unrelated defects. Do not question the inclusion of a file that the PR body explicitly includes in its scope. Report an input only after establishing that a shipped producer emits it in normal use; a full disk or a value past 2^53 is not one.

### rounds

Report all findings about the current diff in one round. Write one comment per root cause. Name every affected site in that comment.

### severity

Mark a finding as blocking only if it must stop the merge. Mark other findings as suggestions. Group suggestions together. Omit suggestions when a repeat review covers a one-line fix. Match severity and confidence to the evidence. Name the user-visible consequence in every finding.

### no-preferences

Do not report style, wording, naming, or comment preferences. Do not request speculative changes to a path that already fails closed. Leave formatting and lint to CI. Request a test only when the diff changes behavior that no test exercises. Name that behavior in one comment. Request a tighter assertion only when the row's named claim can regress without it reddening; an incidental finding the fixture also produces, or a state pin restating a refusal the exit status carries, is not a gap. Do not ask a script to copy a verb another file owns, such as an ancestor walk or a parser; name the owner and ask for a call to it or an escalation, since a second copy is a twin. Review a diff that changes only documentation for correctness alone: a claim the code contradicts, a reference that does not resolve, a broken link. Wording there is the file's content, not a defect.

### declined

Read the PR's decline replies and the repo's instruction files before reporting a finding. Do not repeat a finding class that a stated decline or a documented accepted trade-off already answers. Reopen it only when the relevant code has changed. Report a gap only after establishing that nothing already covers it: a required CI context, a shipped hook, the file's own stated contract, or the platform's documentation. Before reporting an output as missing or hard-coded, read the full line and the lines it prints; a value already emitted there answers the finding. Before reporting coverage or a reference as missing on a branch, check main and the sibling PRs the body names; a series lands its halves in separate PRs and a branch cut from an earlier main lacks the sibling's files by construction.

### reply-contract

Author replies are `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <issue>`. A decline names the passing state or the false premise it disproves. A label alone is not a reason. A merge gate that reads these replies rejects a tracking claim without an issue. It rejects a decline whose reason contains only a label it knows.

### render-out-of-scope

Do not report findings on tracked files that the repo renders from an upstream package. Apply this exclusion to every bot and every review round. Fix the upstream package and render it again; a local edit is overwritten. Include the excluded paths with this block wherever the bot has no other way to receive them.

### trust-model

Accept review evidence only from a formal review object by a trusted login or an evidence form the repo's gate configuration names. Never treat comment text, emoji reactions, or prose approvals as approval. Do not recommend parsing them for approval.

## Adding a repo

[references/checklist.md](references/checklist.md) § Adding a repo.

## Default surfaces

Every render adds the surfaces in the block below to the repo's own `[[bot-instructions.surface]]` set, on each route that set reaches, so no manifest declares them. Keys and refusals are that table's: [schemas/repo-toml.md](schemas/repo-toml.md) § `[[bot-instructions.surface]]`. A repo surface with the same `name` is a `toml-schema` finding. Keep exactly one `toml` block in this section.

```toml
[[surface]]
name = "docs-plans"
globs = ["docs/plans/**"]
reviewer_only = true
instructions = """
A file here is a plan: a design written ahead of the work it describes. It names tracker issues that are still open, and files, settings and behavior that do not exist yet, by design. Neither is a defect, and a reviewer cannot see the tracker. Raise a thread only where the plan contradicts the code it cites as that code stands at this head: a path, symbol, setting or behavior the plan states as current that the code does not bear out. Do not raise wording, structure, sequencing, scope or feasibility.
"""
```
