---
name: bot-instructions
description: "Load to render, check, or adopt a repo's GitHub review-bot instruction files from the shared doctrine and its effective manifest."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
repo-effects:
  configured-by: bot-instructions
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
  staged-checker: "scripts/bot-instructions check --staged"
  removal: "Retire every capability in the order schemas/repo-toml.md § [bot-instructions.bots] gives, which ends in the render that removes the marked files, then remove the package."
  notes:
    - "Only surfaces enabled in the effective [bot-instructions] manifest are written."
    - "The review doctrine is written to [bot-instructions.repo] code_review_path, which defaults to .github/instructions/code-review.md and is refused outside that directory, so every path this package writes is one of those listed above."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Bot Instructions

Renders each enabled review bot's instruction files from the doctrine below and the repository's `[bot-instructions]` manifest table, and checks them.

- Where github-repository-settings declares repository effects, core selects it as the review-file owner, and this package stays installed as its renderer.
- One exception: a github-repository-settings installed only as another package's dependency, and set up neither in this checkout nor in its main checkout, leaves this package the owner until that setup.
- Keep this package's `repo-effects` declaration: core reads it for predecessor discovery and recovery.

## Commands

```bash
.agents/skills/bot-instructions/scripts/bot-instructions render   # validate, then write every enabled output
.agents/skills/bot-instructions/scripts/bot-instructions check    # re-render and compare; --staged reads the index
.agents/skills/bot-instructions/scripts/bot-instructions adopt    # take a hand-written file or region over, once
.agents/skills/bot-instructions/scripts/bot-instructions retire   # revoke kendex automatic rendering on removal; files stay as they are
```

- Options: `bot-instructions --help`.
- The scripts need Python 3.11 or newer and no third-party package. Keep it so, since every repository that installs this package renders with what it already has.
- Before choosing `--output local`, read [schemas/renders.md § Local output](schemas/renders.md#local-output).
- Exit codes: 0 clean, 1 findings, 2 could not complete.
- A manifest with no `[bot-instructions]` table follows [schemas/validators.md](schemas/validators.md) § `orphan`.
- Where commit-guards is installed, its pre-commit chain runs `check --staged`.
- Elsewhere, wire `check --staged` into the repository's own guards. This package ships no hook.
- `render` replaces only a file or region that carries its marker.
- A hand-written file or region at a generated path is taken over by `adopt`, never overwritten: [schemas/renders.md](schemas/renders.md) § Common rules.

## What reads what

| Bot | Reads | Reads from |
|-----|-------|-----------|
| Codex | `AGENTS.md` § Code Review Rules | undocumented |
| Copilot code review | `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `AGENTS.md` | the pull request head |
| CodeRabbit | `.coderabbit.yaml`, plus the `knowledge_base.code_guidelines.filePatterns` files | the pull request head |
| Qodo | `.pr_agent.toml`, `best_practices.md`, `REVIEW.md` | the default branch root |
| Macroscope | `.macroscope/ignore.md`, `.macroscope/correctness/*.md`, `.macroscope/check-run-agents/**`, `.macroscope/approvability.md` | the pull request's most recent commit |

- Codex reads the root `AGENTS.md` plus the nearest nested one.
- CodeRabbit reads `.coderabbit.yaml` whole, beneath any organization or workspace global override.
- This package never writes `.macroscope/check-run-agents/**` or `.macroscope/approvability.md`.
- Macroscope reads the default branch for a fork.
- Codex and Copilot reach the doctrine through a pointer to the rendered `code-review.md`, and CodeRabbit through a file reference.
- Which blocks each destination still carries, and why: [schemas/renders.md](schemas/renders.md) § Doctrine routing.
- Vendor caps and read semantics: [references/limits.md](references/limits.md).

## The pieces

- The effective manifest holds `[bot-instructions]`: bots, repo context, cadence, exclusions, path instructions and doctrine overrides.
- Keys, manifest selection and refusals: [schemas/repo-toml.md](schemas/repo-toml.md).
- Validators: [schemas/validators.md](schemas/validators.md).
- `[bot-instructions.bots] codex` writes the complete doctrine to `[bot-instructions.repo] code_review_path`, which defaults to `.github/instructions/code-review.md`.
- The same flag makes the `AGENTS.md` § Code Review Rules region one directive line naming that file.
- The generator owns only that region of `AGENTS.md` and never creates the file or the heading.
- A repo without the heading:
  1. Adds the heading.
  2. Sets `codex`.
  3. Runs `adopt`.
  4. Runs `render`.
- Region body and bounds: [schemas/renders.md](schemas/renders.md) § `AGENTS.md` § Code Review Rules.
- A repo enabling `codex` renders a canary, a line of its own `[bot-instructions.doctrine.append]`, to check whether the bots follow the pointer.
- No script adds one.
- Before choosing that rule or interpreting a comment, read [references/limits.md § GitHub Copilot code review](references/limits.md#github-copilot-code-review).

## Every rendered config excludes the render trees

- A repo enables `[bot-instructions.exclusions] derive_render` or lists every render tree in `[[bot-instructions.exclusions.path]]`.
- Set construction: [schemas/repo-toml.md](schemas/repo-toml.md) § `[bot-instructions.exclusions]`.
- Placement per bot: [schemas/renders.md](schemas/renders.md) § Doctrine routing.

## A pull request changing its own review

- When the default branch's package copy and the pull request tree's copy are byte-identical, run `check` in CI from the default branch's copy, with `--spec` naming the pull request tree's copy.
- When they differ, the pull request upgrades the package, and the default-branch checker cannot reproduce the candidate's render. Run the candidate's copy, and print a warning that the pull request changes the package.
- The package's own source repository always runs the pull request's checker.

## The render inputs

- `kendex.toml`, plus `kendex-local.toml` when the root declares `is_source_catalog = true`.
- `.kendex-generated.json` when `[bot-instructions.exclusions] derive_render` is on.
- The spec copy's doctrine source, default surfaces and routing table.
- `.bot-instructions/coderabbit-schema.json` when CodeRabbit is on.
- The existing `AGENTS.md` when Codex is on.

## Doctrine

- The `###` blocks below are the doctrine every render carries.
- `--spec` names the spec copy these blocks and the routing table in `schemas/renders.md` are read from; the default is the running copy.
- The section ends at the next level-one or level-two heading, and only a `###` heading inside it is a block.
- Put repo names, paths, issues and repo-specific rules in `[bot-instructions]`, never in a block: every repository that installs this package renders these blocks.

### scope

Raise a defect only in changed lines or code those lines directly break. Report correctness defects, security defects, data loss, fail-open paths in gates, guards, or CI, and an unnamed indirect read of another system. Do not report unrelated defects. Do not question the inclusion of a file that the PR body explicitly includes in its scope. Report an input only after establishing that a shipped producer emits it in normal use; a full disk or a value past 2^53 is not one. A change that derives another system's state indirectly (scrapes its screen or pane, reads a status line, parses output text the system does not document as an interface, or reads its internal files) must name the documented interface it stands in for and why that interface cannot serve. Report a change that omits either as a blocking finding. Reading a documented interface, text or JSON output included, is not this finding.

### rounds

Report all findings about the current diff in one round. Write one comment per root cause. Name every affected site in that comment.

### severity

Mark a finding as blocking only if it must stop the merge. Mark other findings as suggestions. Group suggestions together. Omit suggestions when a repeat review covers a one-line fix. Match severity and confidence to the evidence. Name the user-visible consequence in every finding.

Approve the pull request when the review reports no finding, and when every finding it reports is a suggestion or a nit. Withhold approval only for a blocking finding, and name that finding in the review. Do not withhold approval for a concern you cannot state as a finding. On a later review, a finding the author answered under the reply contract does not block approval unless the code it names changed after the answer.

### no-preferences

Do not report style, wording, naming, or comment preferences. Do not request speculative changes to a path that already fails closed. Leave formatting and lint to CI. Request a test only when its protection justifies its run time and upkeep under code-quality § Tests. Name the reachable failure in one comment. Suggest removal of a test with no protection as a `fix`. Accept an omission the PR body justifies. A missing must-fail control blocks only a new or changed instrument. Request a tighter assertion only where protection matters and the named claim can regress without it reddening; an incidental finding the fixture also produces, or a state pin restating a refusal the exit status carries, is not a gap. Do not ask a script to copy a verb another file owns, such as an ancestor walk or a parser; name the owner and ask for a call to it or an escalation, since a second copy is a twin. Review a diff that changes only documentation for correctness alone: a claim the code contradicts, a reference that does not resolve, a broken link. Wording there is the file's content, not a defect. Do not ask for a document to change beside a code change; a document changes only where the change makes a claim in it false. Do not ask for a decision record for a choice below the decider bar, the decider skill's `SKILL.md` § What warrants a decision record, and why; a local reason is a comment at the code. Do not ask for a plan, a research report or a measurement to be committed under `docs/`; those live in the tracker.

### declined

Read the PR's decline replies and the repo's instruction files before reporting a finding. Do not repeat a finding class that a stated decline or a documented accepted trade-off already answers. Reopen it only when the relevant code has changed. Report a gap only after establishing that nothing already covers it: a required CI context, a shipped hook, the file's own stated contract, or the platform's documentation. Before reporting an output as missing or hard-coded, read the full line and the lines it prints; a value already emitted there answers the finding. Before reporting coverage or a reference as missing on a branch, check main and the sibling PRs the body names; a series lands its halves in separate PRs and a branch cut from an earlier main lacks the sibling's files by construction.

### reply-contract

Render author replies as `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <issue>`. Classify findings and supply decline reasons under `.agents/skills/reviewer/references/finding-disposition.md` § Decision flow.

### render-out-of-scope

Do not report findings on tracked files that the repo renders from an upstream package. Apply this exclusion to every bot and every review round. Fix the upstream package and render it again; a local edit is overwritten. Include the excluded paths with this block wherever the bot has no other way to receive them.

### trust-model

Read approval from GitHub's formal review state under the repository's rulesets. Never treat comment text, emoji reactions, or prose approvals as approval. Do not recommend parsing them for approval.

## Adding a repo

When adding a repository, follow [workflows/add-repository.md](workflows/add-repository.md).

## Default surfaces

Every render adds the surfaces in the block below to the repo's own `[[bot-instructions.surface]]` set, on each route that set reaches, so no manifest declares them. Keys and refusals are that table's: [schemas/repo-toml.md](schemas/repo-toml.md) § `[[bot-instructions.surface]]`. A repo surface with the same `name` is a `toml-schema` finding. Keep exactly one `toml` block in this section.

```toml
[[surface]]
name = "docs-architecture"
globs = ["docs/architecture/**"]
reviewer_only = true
instructions = """
A file here is a principle doc: one reader's task and the harmful mistake it prevents, with the approach, why, the rules and one canonical code example, whatever folders that task crosses. Raise a thread only where it contradicts the code it describes as that code stands at this head: a path, symbol, setting, rule or enforcing check the doc states that the code does not bear out. Do not raise wording, structure or length, and do not ask it to walk through code, list files or tests, or record history, dates or measurements; those do not belong here. Do not ask for a doc here to change beside a code change unless the change makes a claim in it false.
"""
```
