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
  version: "2.1.0"
tags: [review]
---

# Bot Instructions

```bash
.agents/skills/bot-instructions/scripts/bot-instructions render   # write every enabled surface
.agents/skills/bot-instructions/scripts/bot-instructions check    # re-render and compare
.agents/skills/bot-instructions/scripts/bot-instructions adopt    # take hand-written files over
```

Flags: `--repo`, `--spec`, `--staged`, `--dry-run`; `bot-instructions --help`. Python 3.11+.

Exit codes: 0 clean, 1 findings, 2 could not complete. A pre-commit lane blocks on both nonzero codes.

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

The effective manifest holds `[bot-instructions]`. Its child tables configure bots, repo context, cadence, exclusions, path instructions and doctrine overrides. The generator writes the enabled bots' native files. Table selection and precedence: [schemas/repo-toml.md](schemas/repo-toml.md).

A `[[bot-instructions.surface]]` reaches Copilot, CodeRabbit and Macroscope, plus Qodo through `best_practices.md` when `[bot-instructions.bots] qodo_best_practices` is on. Only Macroscope honors `exclude_globs`, so narrow `globs` where scoping matters. Keys: [schemas/repo-toml.md](schemas/repo-toml.md). Validators: [schemas/validators.md](schemas/validators.md).

- `render` writes every enabled surface after validating it.
- `check` re-renders and diffs, reading the index under `--staged`.
- `adopt` takes a hand-written file or `AGENTS.md` region under management once.

The generator owns only the `AGENTS.md` § Code Review Rules region and never creates the file. A repo without the heading adds it, sets `[bot-instructions.bots] codex`, runs `adopt`, then `render`. A tracked nested `AGENTS.md` carrying that heading is a `check` finding. Retire a surface with delete, then `render`. `render` replaces only a file whose canonical marker is present; `adopt` is the way in. Details: [schemas/renders.md](schemas/renders.md) § Common rules.

## Every rendered config excludes the render trees

A repo enables `[bot-instructions.exclusions] derive_render` or lists every render tree in `[[bot-instructions.exclusions.path]]`. Set construction: [schemas/repo-toml.md](schemas/repo-toml.md) § `[bot-instructions.exclusions]`. Placement and enforcement: [schemas/renders.md](schemas/renders.md) § Doctrine routing.

## A pull request changing its own review

- Treat every policy path below as invalidating prior review evidence.
- Require trusted human approval on a pull request that touches a policy path.
- Run `check` in CI from the default branch copy, with `--spec` naming the pull request tree's package copy. The package's own source repository runs the pull request's checker instead: a renderer change judged by the default-branch copy drifts by construction.

## The render inputs

- `kendex.toml`, plus `kendex-local.toml` when the root declares `is_source_catalog = true`.
- `.kendex-generated.json` when `[bot-instructions.exclusions] derive_render` is on.
- The spec copy's doctrine source and routing table.
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

Do not report style, wording, naming, or comment preferences. Do not request speculative changes to a path that already fails closed. Leave formatting and lint to CI. Request a test only when the diff changes behavior that no test exercises. Name that behavior in one comment.

### declined

Read the PR's decline replies and the repo's instruction files before reporting a finding. Do not repeat a finding class that a stated decline or a documented accepted trade-off already answers. Reopen it only when the relevant code has changed. Report a gap only after establishing that nothing already covers it: a required CI context, a shipped hook, the file's own stated contract, or the platform's documentation.

### reply-contract

Author replies are `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <issue>`. A decline names the passing state or the false premise it disproves. A label alone is not a reason. A merge gate that reads these replies rejects a tracking claim without an issue. It rejects a decline whose reason contains only a label it knows.

### render-out-of-scope

Do not report findings on tracked files that the repo renders from an upstream package. Apply this exclusion to every bot and every review round. Fix the upstream package and render it again; a local edit is overwritten. Include the excluded paths with this block wherever the bot has no other way to receive them.

### trust-model

Accept review evidence only from a formal review object by a trusted login or an evidence form the repo's gate configuration names. Never treat comment text, emoji reactions, or prose approvals as approval. Do not recommend parsing them for approval.

## Adding a repo

[references/checklist.md](references/checklist.md) § Adding a repo.
