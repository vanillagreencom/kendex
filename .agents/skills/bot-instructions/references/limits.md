# Vendor limits and read semantics

- Every number the generator enforces that comes from a vendor is here with the page that states it.
- A vendor number the generator holds and this file does not carry is a defect: the generator encodes what a vendor documents, not what someone remembers.

**A row says which kind of number it is.**

- A **cap** is a boundary the vendor rejects on: exceed it and the vendor discards or refuses the input.
- A **recommendation** is writing guidance the vendor gives with no stated consequence.
- Where the generator holds a number taken from a recommendation, that is a **package budget**, with its own row beside the recommendation.
- Never present a recommendation as a cap: a failure message would then blame the vendor for a refusal no vendor states.

Vendor caps move. When a render fails on a limit that looks wrong, re-read the cited page before raising the number in code.

## CodeRabbit

- Source of truth is the published schema itself, `https://coderabbit.ai/integrations/schema.v2.json`.
- Every repo vendors it rather than fetching it at check time.
- Prose reference: <https://docs.coderabbit.ai/reference/configuration>.

| What | Value | Where | Kind |
|------|-------|-------|------|
| `tone_instructions` | 250 characters | schema `maxLength` | cap |
| `reviews.path_instructions[].instructions` | 20,000 characters | schema `maxLength` | cap |
| `reviews.labeling_instructions[].instructions` | 3,000 characters | schema `maxLength` | cap |
| `reviews.finishing_touches.custom[].instructions` | 10,000 characters | schema `maxLength` | cap |
| `reviews.finishing_touches.custom[]` | 5 entries | schema `maxItems` | cap |
| `reviews.pre_merge_checks.custom_checks[].instructions` | 10,000 characters | schema `maxLength` | cap |
| `reviews.pre_merge_checks.custom_checks[]` | 50 entries | schema `maxItems` | cap |
| `reviews.profile` | `quiet`, `chill`, `assertive` | schema `enum` | cap |
| Unknown top-level key | rejected | root `additionalProperties: false` | cap |

Only the first two are reachable from this package's renders.

**Precedence.** <https://docs.coderabbit.ai/guides/configuration-overview>

1. Workspace global overrides.
2. Organization global overrides.
3. The repo's `.coderabbit.yaml`.
4. Central repository configuration.
5. Repository dashboard.
6. Organization dashboard.
7. Workspace settings.
8. Defaults.

- An unset key resolves down that ladder per setting rather than falling straight to the schema default.
- Every layer below the file is unversioned.

**Read semantics.** The file is read from the pull request's head branch, so a pull request can change its own review configuration.

**`base_branches`.**

- Setting `reviews.auto_review.base_branches` to `[".*"]` rather than naming the default branch is fleet experience, not documented behavior: naming the branch has been observed to skip pull requests targeting it.
- The wildcard also covers stacked pull requests.

**Invalid file.**

- CodeRabbit does not document what it does with a config that fails its schema.
- Fleet experience is that it discards the file whole and reviews with resolved settings, saying nothing on the pull request.
- The `coderabbit-schema` validator assumes that.

**`path_filters` and sparse-checkout.**

- The schema's own description states these patterns also apply to `git sparse-checkout` when cloning.
- Plain globs only.
- Extglob and brace patterns pass minimatch and match nothing in sparse-checkout.

## GitHub Copilot code review

<https://docs.github.com/en/copilot/reference/custom-instructions-support> and <https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions>

| What | Value | Kind |
|------|-------|------|
| Character cap on instruction files | none is documented | — |
| Size guidance | "Instructions must be no longer than 2 pages" | recommendation |
| `[bot-instructions.budgets] copilot_chars` | 6000 characters | package budget |
| `excludeAgent` values | `code-review`, `cloud-agent` | — |
| `applyTo` on an empty or absent value | the file matches nothing and never loads | — |
| `applyTo` | a single string holding comma-separated globs | — |

- Third-party writeups still cite a 4,000-character cut-off on `copilot-instructions.md` and `*.instructions.md`; GitHub removed it.
- `copilot_chars` is this package's reading of two pages, and the default a repo may raise.
- The `excludeAgent` value names the agent the file is hidden **from**:
  - `cloud-agent` keeps a file from the working agent and leaves code review reading it.
  - `code-review` does the reverse.
  - They are not interchangeable.

**What code review reads.**

- On GitHub.com: `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, agent instructions (`AGENTS.md`), and organization instructions.
- Personal instructions are not read by code review.
- Path-specific instructions are supported by code review on GitHub.com, JetBrains and Xcode.
- In VS Code and Visual Studio, only the repo-wide file applies.

**The rendered `code-review.md` is on none of those lists.**

- It has no `.instructions.md` suffix and no `applyTo` frontmatter, so Copilot does not load it.
- It arrives only if the bot opens the file the loaded instructions name.
- **No vendor page documents that any bot follows an in-file reference.** The pointer rests on fleet experience.
- A bot that does not follow it reviews with no repo rules and posts normally throughout.
- A canary detects that failure: one harmless rule exclusive among the files the bot under test reads, so its appearance in a comment proves the comment was written against the pointed file.
- kendex renders one as a `[bot-instructions.doctrine.append]` on `rounds`, asking every comment to open with `read: .github/instructions/code-review.md`.
- An append on a block the `copilot-instructions.md` routing column does not carry is exclusive for Codex and Copilot, because no other file either reads carries that block. [../schemas/renders.md](../schemas/renders.md) § Doctrine routing note (b) defines that column.
- An append to a block the column does carry, today `severity`, is not a Copilot canary: Copilot loads `copilot-instructions.md` itself, so the append can appear in its comments without Copilot following the pointer.
- No append is exclusive in general, since it also reaches every other destination its block routes to: both `pr_agent` guidance keys, `REVIEW.md` and `macroscope doctrine.md`.
- A repo running Qodo or Macroscope needs a rule those surfaces do not carry.

`cloud-agent` is the current spelling, quoted from the page above: "Use either `"code-review"` or `"cloud-agent"`." Older material spells the same agent `coding-agent`. Change that value only after re-reading the cited page.

**Read semantics.** "When reviewing a pull request, Copilot reads repository custom instructions, agent instructions, and agent skills from the head branch (the branch with your changes), not the base branch."

**Precedence.** Personal, then repository, then organization.

**Content exclusion.** <https://docs.github.com/en/copilot/how-tos/configure-content-exclusion/exclude-content-from-copilot>

- Code review honors repository, organization and enterprise content-exclusion settings.
- Exclusion is a settings-UI feature and cannot be expressed in any repo file.

**Approvals.** <https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review> and <https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-code-review>

- By default Copilot leaves a Comment review, which counts toward no required approval.
- Approvals are off by default and are set at the enterprise, organization and repository level.
- The repository setting can limit counted approvals to pull requests whose every changed file matches one of up to 15 globs.
- Every review states an approval assessment in its overview comment.
- A push dismisses an approval like a person's.
- Copilot reviews again only on a push, with automatic review of new pushes on, or on a re-request.
- A reply to its comments is not visible to it.
- <https://docs.github.com/en/copilot/tutorials/customize-code-review> lists changing the overview comment and blocking a merge among the instruction types code review does not support.
- No vendor page says instructions move the assessment.
- Fleet experience says they do: on kendex, assessments of "Needs a closer look" with no finding quoted a repository rule that a policy change needs a trusted person's approval.
- [../schemas/renders.md](../schemas/renders.md) § Doctrine routing note (b) builds on that.

## Codex code review

<https://learn.chatgpt.com/docs/third-party/github>

| What | Value |
|------|-------|
| Instruction file | `AGENTS.md`, and nothing else |
| Following a reference out of that file | not documented; see § GitHub Copilot code review, **The rendered `code-review.md`** |
| Read from which branch | not documented |
| Section | `## Code Review Rules` |
| Nesting | root guidance combines with the nearest nested `AGENTS.md` covering each changed file |
| Documented size limit | none |
| File-based exclusion | none exists |

- "Add a `## Code Review Rules` section to the file closest to the code the rules govern."
- One-off steering happens in the trigger comment, not in a file.

## Qodo

- Qodo's docs are split by product line, and a row's line decides whether it applies here.
- Qodo Review is the current product, under `docs.qodo.ai/...`.
- Qodo Merge is the legacy one, under `docs.qodo.ai/v1/...`.
- This package's `[review_agent]` keys are Review and its `[pr_reviewer]` keys are Merge, which is why the render writes both.

<https://docs.qodo.ai/install-and-configure/configuration-overview/configuration-file>, <https://docs.qodo.ai/governance/rule-enforcement/without-rule-system/best-practices>

| What | Value | Kind | Line |
|------|-------|------|------|
| `best_practices.md` per file | "Keep files relatively short (under ~800 lines)" | recommendation | Review |
| `[bot-instructions.budgets] qodo_best_practices_lines` | 800 lines | package budget | — |
| Automatic `best_practices.md` loading | a Qodo Merge (commercial) feature | — | Merge |

- The Merge page at `/v1/features/best-practices` gives the same 800-line words.
- `qodo_best_practices_lines` is this package's reading of that recommendation, and the default a repo may raise.
- Open-source PR-Agent does not load `best_practices.md` automatically.
- Qodo states no rejection or truncation at any length.
- No accumulated limit across Qodo's sources and no `repo_context_max_lines` default is on a current page, so the generator holds neither.

**Configuration locations.**

- Repo root `.pr_agent.toml`, documented as the root of the default branch.
- A repo wiki page of the same name.
- A `pr-agent-settings` repository at project or organization level.
- The Qodo portal.

**Precedence.**

- The docs state that project-level settings take precedence over organization-level, and that "a repository's local configuration always overrides both".
- They do not rank the repo root against the repo wiki.
- The package ships the root file and treats the wiki as a channel to keep empty, which is correct under either ranking.

**Sections that matter.** <https://docs.qodo.ai/code-review/extra-instructions>

- `/review` reads `[pr_reviewer] extra_instructions`.
- `/agentic_review` reads `[review_agent]`, which carries one key per agent:
  - `issues_user_guidelines` for bug, security and performance detection.
  - `compliance_user_guidelines` for rule checking.
  - `smart_router_extra_instructions` for the agent deciding review depth.

**Exclusions.**

- `[ignore]` globs.
- Pull-request-level keys: `ignore_pr_labels`, `ignore_pr_authors`, `ignore_pr_title`, branch filters.
- `allow_only_specific_folders`.
- There is no per-path instruction mechanism.

**`REVIEW.md`.** <https://docs.qodo.ai/governance/use-review-md>

- A root file of plain-markdown review guidelines all Qodo review agents follow.
- Enabled once in the portal under Configurations → Context.
- Qodo product functionality, not an open-source PR-Agent guarantee.

## Macroscope

<https://docs.macroscope.com/custom-instructions>, <https://docs.macroscope.com/check-run-agents>, <https://docs.macroscope.com/bug-detection-and-fixes#macroscope-ignore>

| What | Value |
|------|-------|
| Instruction files | `.macroscope/correctness/**/*.md` |
| Reserved names at `.macroscope/` root | `ignore.md`, `approvability.md` |
| Governing file | `.macroscope/correctness/correctness.md` |
| Governing-file frontmatter | `waitsFor`, `requires`, `waitsForTimeout`, `waitsForDiscoveryTimeout` |
| `waitsForTimeout` default | 20 minutes |
| `waitsForDiscoveryTimeout` default | 1 minute |
| Frontmatter on a correctness file | `include`, `exclude`, both optional glob arrays |
| Evaluation order | `exclude` after `include` |
| Check-run agent `title` | 60 characters |
| Check-run agent `reasoning` | `off`, `low`, `medium`, `high`, `xhigh` |
| Check-run agent `effort` | `low`, `medium`, `high` |
| Check-run agent `input` | `full_diff`, `code_object`, `pr_metadata` |
| Check-run agent `conclusion` | `neutral`, `failure` |

- Instruction files are `*.md` only, and `README.md` is ignored.
- The governing file sits "at the top level of the directory, spelled exactly that way".
- The governing file's frontmatter configures the whole correctness check.
- Omitted frontmatter on a correctness file applies repo-wide.
- Subdirectories are organizational only.
- Multiple instruction files matching one changed file stack.
- Only the governing file's four fields set the check run's prerequisites and timeouts.

**`ignore.md` grammar.**

- Simplified glob syntax, one pattern per line.
- Lines starting with `#` are comments, and blank lines are ignored.
- `**` matches across directories, `*` within one path segment, `?` one character.
- A pattern with no `/` matches at any depth.
- Maximum 1,000 patterns.
- Matching is deterministic with no override mechanism.

**`ignore.md` scope.**

- Repository-wide exclusion, applying to every check run.
- An agent's own `include` patterns override it, so give a check-run agent no broad `include`.

**Read semantics.**

- Configuration is read from the most recent commit on the pull request, so an edit takes effect on that pull request immediately.
- A pull request from an external fork always reads configuration from the default branch.

**Settings-only.** Whether correctness review runs, detection mode, minimum severity to comment, maximum automatic runs, and spend caps are dashboard settings with no repo-file equivalent.
