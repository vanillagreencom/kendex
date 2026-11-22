# Per-repo settings checklist

## Before the first pass

- [ ] `python3 --version` is 3.11 or newer where the verbs run: locally and on whatever runs this repo's guards.
- [ ] `check --staged` runs at commit, as [SKILL.md § Commands](../SKILL.md#commands) sets out.
- [ ] No wrapper runs it where commit-guards already runs it.

## Adding a repo

When adding a repository, follow [workflows/add-repository.md](../workflows/add-repository.md).

## The settings

- Every bot here has at least one setting that lives in a web UI and cannot be expressed in any file the repo contains.
- Skip one and the repo looks fully configured while a bot reviews nothing, or reviews with the wrong scope, and no render or validator can tell.
- An administrator can change any of it without touching the repo.
- Work one capability's section at a time, as the settings step of [workflows/add-repository.md](../workflows/add-repository.md).
- Record each line's outcome in the repo beside the TOML, so the next person can tell a deliberate `false` from an unanswered question.
- A capability whose section here is unanswered stays `false` in `[bot-instructions.bots]`: a `true` flag renders files that reach nothing.
- A section answered but never followed by setting the flag leaves the reverse, a bot enabled at the vendor reading nothing this package wrote.

## GitHub Copilot code review

- [ ] Copilot is enabled for the repository, under an org or enterprise plan that covers code review.
- [ ] Automatic review is enabled, either per repository or through an organization ruleset requiring Copilot as a reviewer. Without it the instruction files load only when someone requests a review by hand.
- [ ] Custom instructions are enabled for code review in the repository's Copilot settings. The files exist regardless; this toggle decides whether review reads them.
- [ ] Content exclusion paths are set, if any are wanted: Settings → Copilot → Content exclusion, in YAML fnmatch form. Anything in `[[bot-instructions.exclusions.path]]` that must also be invisible to Copilot is entered here by hand.
- [ ] The organization's runner-type setting is understood. An org admin can set a default runner type across all repositories and lock it, overriding per-repo configuration.

## Codex code review

- [ ] The Codex GitHub app is installed on the repository.
- [ ] Code review is enabled for this repository at <https://chatgpt.com/codex/settings/code-review>. Requires push or admin permission on the repo.
- [ ] Automatic reviews are on, or the team knows reviews come only from an `@codex review` comment.
- [ ] Security-review scope is set, if the repo wants it.

## CodeRabbit

- [ ] The CodeRabbit app is installed and the repository is enabled in the organization.
- [ ] No organization or workspace global override is set. Those outrank the repo file, and a repo cannot see them. If one exists, everything in `.coderabbit.yaml` is advisory and the render is misleading.
- [ ] `@coderabbitai configuration` has been run once on a pull request and its resolved output matches the committed file. This is the only way to confirm the file was accepted rather than discarded.
- [ ] `.bot-instructions/coderabbit-schema.json` is current. A stale copy rejects a newly valid file.
- [ ] The repo records where that copy came from and how to refresh it. A copy carrying a JSON Schema keyword the validator does not implement blocks every render until the validator is updated.
- [ ] Integrations the repo wants (Linear, Jira) are authorized. The file names the tracker; the authorization is a UI step.

Once the file lands, change what it controls in the TOML, not in the dashboard: the file outranks the dashboard, and only a global override outranks the file.

## Qodo

- [ ] The Qodo app is installed on the repository and seats cover it.
- [ ] Which Qodo product this repo is on is known. Qodo Merge, the commercial product, loads `best_practices.md` automatically, and open-source PR-Agent does not.
- [ ] `[bot-instructions.bots] qodo_best_practices` is `false` where the file would be inert.
- [ ] No `.pr_agent.toml` page exists in the repository wiki. A wiki page of that name applies without a commit and is invisible to version control and to the generator.
- [ ] No `pr-agent-settings` repository exists at the organization or project level carrying settings this repo does not expect.
- [ ] What other best-practices sources Qodo loads for this repo is known. Organization and mapped-repository files layer above the generated one, the generator cannot see them, and nothing here bounds the total.
- [ ] Before setting `[bot-instructions.bots] qodo_review_md`: the portal toggle under Configurations → Context, "REVIEW.md instructions", is on. Without it the file is inert.

## Macroscope

- [ ] The Macroscope app is installed on the repository.
- [ ] Correctness review is enabled.
- [ ] Its detection mode and minimum comment severity are set. These have no repo-file equivalent.
- [ ] Maximum automatic runs per pull request is set.
- [ ] Spend caps are set: monthly, per pull request, and per review.
- [ ] The generated `.macroscope/ignore.md` excludes what it names. Confirm once that the exclusions took effect.
- [ ] A repo that lints every tracked `*.md` excludes `.macroscope/ignore.md` from that lint.
- [ ] That exclusion states why: the file is Macroscope's glob-per-line grammar, where `#` opens a comment, not a heading.

## Glob dialect

- [ ] An exclusion took effect on Copilot, on Qodo, on Macroscope, and through CodeRabbit's minimatch. The package's tests measure only git's wildmatch; the `applyTo`, `[ignore]` and `include` matchers are unpublished and minimatch needs a Node runtime, so this line is the only confirmation those four get.

## If the repo has its own guard over these files

- [ ] Every predicate that guard uses is at least as loose as the render's. A guard slicing `AGENTS.md` on `^## Code Review Rules$`, matching the directive line inside it, or matching a pointer sentence on one line of `.github/copilot-instructions.md`, is reading bytes this package writes; the render spec pins all three.
- [ ] A repo adding a fourth predicate reconciles it before rendering rather than at adoption time.
- [ ] A guard pinning the reply form reads the pointed `code-review.md`, not the `AGENTS.md` region. The region carries the directive line and nothing else, so a guard still matching `Tracked: <PREFIX>-<n>` there reads the form as gone.
- [ ] `[bot-instructions.repo] tracker` is set wherever a guard pins the tracked reply form. Without it the render leaves the generic placeholder and the guard reads the form as gone.
- [ ] Retiring a bot whose file another check requires is a pointer move first, then the deletion. Where a repo's own gate reads `.github/copilot-instructions.md`, `[bot-instructions.bots] copilot = false` means moving what that gate reads before removing the file.
