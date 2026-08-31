# Vendor limits and read semantics

Every number the generator enforces is here with the page that states it. A
limit the generator holds that this file does not carry is a defect: the
generator's job is to encode what a vendor documents, not what someone
remembers.

Vendor caps move. When a render fails on a limit that looks wrong, re-read the
cited page before raising the number in code.

## CodeRabbit

Source of truth is the published schema itself,
`https://coderabbit.ai/integrations/schema.v2.json`, which every repo vendors
rather than fetching at check time. Prose reference:
<https://docs.coderabbit.ai/reference/configuration>.

| What | Value | Where |
|------|-------|-------|
| `tone_instructions` | 250 characters | schema `maxLength` |
| `reviews.path_instructions[].instructions` | 20,000 characters | schema `maxLength` |
| `reviews.labeling_instructions[].instructions` | 3,000 characters | schema `maxLength` |
| `reviews.finishing_touches.custom[].instructions` | 10,000 characters, 5 entries | schema `maxLength`, `maxItems` |
| `reviews.pre_merge_checks.custom_checks[].instructions` | 10,000 characters, 50 entries | schema `maxLength`, `maxItems` |
| `reviews.profile` | `quiet`, `chill`, `assertive` | schema `enum` |
| Unknown top-level key | rejected | root `additionalProperties: false` |

Only the first two are reachable from this package's renders. The rest are
listed because a future render that reaches them inherits a real cap.

**Precedence.** Workspace global overrides, then organization global overrides,
then the repo's `.coderabbit.yaml`, then central repository configuration, then
repository dashboard, organization dashboard, workspace settings, defaults. An
unset key resolves down that ladder per setting rather than falling straight to
the schema default, which is why the render writes full state: every layer
below the file is unversioned.
<https://docs.coderabbit.ai/guides/configuration-overview>

**Read semantics.** The file is read from the pull request's head branch, so a
pull request can change its own review configuration.

**`base_branches`.** Setting `reviews.auto_review.base_branches` to `[".*"]`
rather than naming the default branch is fleet experience, not documented
behavior: naming the branch has been observed to skip pull requests targeting
it. The wildcard also covers stacked pull requests.

**Invalid file.** CodeRabbit does not document what it does with a config that
fails its schema. Fleet experience is that it discards the file whole and
reviews with resolved settings, saying nothing on the pull request. The
`coderabbit-schema` validator assumes that, because the assumption costs a
validator and the alternative costs an inert config nobody notices.

**`path_filters` and sparse-checkout.** The schema's own description states
these patterns also apply to `git sparse-checkout` when cloning. Plain globs
only. Extglob and brace patterns pass minimatch and match nothing in
sparse-checkout.

## GitHub Copilot code review

<https://docs.github.com/en/copilot/reference/custom-instructions-support> and
<https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions>

| What | Value |
|------|-------|
| Character cap on instruction files | none is documented. Third-party writeups still cite a 4,000-character cut-off on `copilot-instructions.md` and `*.instructions.md`; GitHub removed it |
| Size guidance | "Instructions must be no longer than 2 pages" |
| `excludeAgent` values | `code-review`, `cloud-agent` |
| `applyTo` on an empty or absent value | the file matches nothing and never loads |
| `applyTo` | a single string holding comma-separated globs |

**What code review reads.** On GitHub.com: `.github/copilot-instructions.md`,
`.github/instructions/**/*.instructions.md`, agent instructions (`AGENTS.md`),
and organization instructions. Personal instructions are not read by code
review. Path-specific instructions are supported by code review on GitHub.com,
JetBrains and Xcode, but not in VS Code or Visual Studio, where only the
repo-wide file applies.

`cloud-agent` is the current spelling, quoted from the page above: "Use either
`"code-review"` or `"cloud-agent"`." Older material spells the same agent
`coding-agent`, from before the rename, and material predating both calls it
the coding agent in prose. A change to that value belongs to a re-read of the
cited page, not to a recollection.

That AGENTS.md row is worth reading twice. Copilot code review does read it,
which is a reason to keep reviewer-only doctrine out of `AGENTS.md` and in a
file carrying `excludeAgent`, rather than a reason to consolidate everything
into one file.

**Read semantics.** "When reviewing a pull request, Copilot reads repository
custom instructions, agent instructions, and agent skills from the head branch
(the branch with your changes), not the base branch."

**Precedence.** Personal, then repository, then organization.

**Content exclusion.** Code review honors repository, organization and
enterprise content-exclusion settings. Exclusion itself is a settings-UI
feature and cannot be expressed in any repo file, which is why it is a
checklist item.
<https://docs.github.com/en/copilot/how-tos/configure-content-exclusion/exclude-content-from-copilot>

## Codex code review

<https://learn.chatgpt.com/docs/third-party/github>

| What | Value |
|------|-------|
| Instruction file | `AGENTS.md`, and nothing else |
| Read from which branch | not documented |
| Section | `## Code Review Rules` |
| Nesting | root guidance combines with the nearest nested `AGENTS.md` covering each changed file |
| Documented size limit | none |
| File-based exclusion | none exists |

"Add a `## Code Review Rules` section to the file closest to the code the rules
govern." One-off steering happens in the trigger comment, not in a file.

## Qodo

Qodo's docs are split by product line, and a row's line decides whether it
applies here. Qodo Review is the current product, under
`docs.qodo.ai/...`; Qodo Merge is the legacy one, under `docs.qodo.ai/v1/...`.
This package's `[review_agent]` keys are Review and its `[pr_reviewer]` keys are
Merge, which is why the render writes both.

<https://docs.qodo.ai/install-and-configure/configuration-overview/configuration-file>,
<https://docs.qodo.ai/governance/rule-enforcement/without-rule-system/best-practices>

| What | Value | Line |
|------|-------|------|
| `best_practices.md` per file | "Keep files relatively short (under ~800 lines)" | Review, and the same cap on the Merge page at `/v1/features/best-practices` |
| Automatic `best_practices.md` loading | a Qodo Merge (commercial) feature, absent from open-source PR-Agent | Merge |

800 lines per file is the only best-practices cap on a live vendor page. An
accumulated cap across every source Qodo loads, and an open-source PR-Agent
`repo_context_max_lines` default, both appeared in material that is now gone:
the page they came from returns 404 and neither number is on any page that
replaced it. They are not enforced anywhere in this package, because a number
this file cannot cite is a number the generator does not hold.

**Configuration locations.** Repo root `.pr_agent.toml`, documented as the root
of the default branch, a repo wiki page of the same name, a
`pr-agent-settings` repository at project or organization level, and the Qodo
portal.

**Precedence.** The docs state that project-level settings take precedence over
organization-level, and that "a repository's local configuration always
overrides both". They do not rank the repo root against the repo wiki. The
package ships the root file and treats the wiki as a channel to keep empty,
which is correct under either ranking; the checklist carries the step that
confirms no wiki page exists.

**Sections that matter.** `/review` reads `[pr_reviewer] extra_instructions`.
`/agentic_review` reads `[review_agent]`, which carries one key per agent:
`issues_user_guidelines` for bug, security and performance detection,
`compliance_user_guidelines` for rule checking, and
`smart_router_extra_instructions` for the agent deciding review depth.
<https://docs.qodo.ai/code-review/extra-instructions>

**Exclusions.** `[ignore]` globs plus pull-request-level keys
(`ignore_pr_labels`, `ignore_pr_authors`, `ignore_pr_title`, branch filters)
and `allow_only_specific_folders`. There is
no per-path instruction mechanism.

**`REVIEW.md`.** A root file of plain-markdown review guidelines all Qodo review
agents follow, enabled once in the portal under Configurations → Context. Qodo
product functionality, not an open-source PR-Agent guarantee.
<https://docs.qodo.ai/governance/use-review-md>

## Macroscope

<https://docs.macroscope.com/custom-instructions>,
<https://docs.macroscope.com/check-run-agents>

| What | Value |
|------|-------|
| Instruction files | `.macroscope/correctness/**/*.md`, `*.md` only, `README.md` ignored |
| Reserved names at `.macroscope/` root | `ignore.md`, `approvability.md` |
| Governing file | `.macroscope/correctness/correctness.md`, "at the top level of the directory, spelled exactly that way" |
| Governing-file frontmatter | `waitsFor`, `requires`, `waitsForTimeout` (default 20 minutes), `waitsForDiscoveryTimeout` (default 1 minute), configuring the whole correctness check |
| Frontmatter on a correctness file | `include`, `exclude`, both optional glob arrays |
| Evaluation order | `exclude` after `include`; omitted frontmatter applies repo-wide |
| Check-run agent `title` | 60 characters |
| Check-run agent enums | `reasoning`: `off`, `low`, `medium`, `high`, `xhigh`. `effort`: `low`, `medium`, `high`. `input`: `full_diff`, `code_object`, `pr_metadata`. `conclusion`: `neutral`, `failure` |

Subdirectories are organizational only. Multiple instruction files matching one
changed file stack. The governing file is the exception to "a correctness file
is just instructions": its four fields set the check run's prerequisites and
timeouts, and no other file can carry them.

**`ignore.md` scope.** Repository-wide exclusion, applying to every check run.
An agent's own `include` patterns override it, which is a reason not to give an
agent a broad `include`.

**Read semantics.** Configuration is read from the most recent commit on the
pull request, so an edit takes effect on that pull request immediately. A pull
request from an external fork always reads configuration from the default
branch.

**Settings-only.** Whether correctness review runs, detection mode, minimum
severity to comment, maximum automatic runs, and spend caps are dashboard
settings with no repo-file equivalent.
