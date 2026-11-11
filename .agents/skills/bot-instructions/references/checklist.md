# Per-repo settings checklist

## Before the first pass

- [ ] `python3 --version` is 3.11 or newer where the verbs run — locally and on whatever runs this repo's guards. The generator needs `tomllib` and nothing else, and it refuses to start on an older one rather than half-parsing a TOML.
- [ ] `check --staged` runs at commit. Where `commit-guards` is installed its pre-commit chain runs it as a lane; write no wrapper for it. Elsewhere, wire `check --staged` into whatever runs this repo's other guards so it judges one coherent staged state.

## Adding a repo

When adding a repository, follow [workflows/add-repository.md](../workflows/add-repository.md).

## The settings

Every bot here has at least one setting that lives in a web UI and cannot be expressed in any file the repo contains. Skip one and the repo looks fully configured while a bot reviews nothing, or reviews with the wrong scope, and no render or validator can tell.

Work one capability's section at a time, as the settings step of [workflows/add-repository.md](../workflows/add-repository.md), and record each line's outcome in the repo beside the TOML so the next person can tell a deliberate `false` from an unanswered question.

A capability whose section here is unanswered stays `false` in `[bot-instructions.bots]`. A `true` flag renders files that reach nothing, which is worse than no files at all — and a section answered but never followed by setting the flag leaves the reverse, a bot enabled at the vendor reading nothing this package wrote.

None of this state is machine-readable from the repo, and an administrator can change any of it without touching the repo. Every check here can keep passing after a bot has been switched off in a settings page nobody looked at, so the workflow's [After the checklist smoke test](../workflows/add-repository.md#after-the-checklist) is what actually confirms the set.

## GitHub Copilot code review

- [ ] Copilot is enabled for the repository, under an org or enterprise plan that covers code review.
- [ ] Automatic review is enabled, either per repository or through an organization ruleset requiring Copilot as a reviewer. Without it the instruction files load only when someone requests a review by hand.
- [ ] Custom instructions are enabled for code review in the repository's Copilot settings. The files exist regardless; this toggle decides whether review reads them.
- [ ] Content exclusion paths are set, if any are wanted. Settings → Copilot → Content exclusion, in YAML fnmatch form. This is the only exclusion mechanism Copilot has, and it is not a repo file. Anything in `[[bot-instructions.exclusions.path]]` that must also be invisible to Copilot is entered here by hand.
- [ ] The organization's runner-type setting is understood. An org admin can set a default runner type across all repositories and lock it, overriding per-repo configuration.

## Codex code review

- [ ] The Codex GitHub app is installed on the repository.
- [ ] Code review is enabled for this repository at <https://chatgpt.com/codex/settings/code-review>. Requires push or admin permission on the repo.
- [ ] Automatic reviews are on, or the team knows reviews come only from an `@codex review` comment.
- [ ] Security-review scope is set, if the repo wants it.

Nothing else about Codex is configurable from the repo. `AGENTS.md` § Code Review Rules is its entire instruction surface, and the directive there is what sends it to the pointed `code-review.md`. Codex has no file-based exclusion mechanism at all, which is why that file carries every doctrine block rather than a subset.

## CodeRabbit

- [ ] The CodeRabbit app is installed and the repository is enabled in the organization.
- [ ] No organization or workspace global override is set. Those outrank the repo file, and a repo cannot see them. If one exists, everything in `.coderabbit.yaml` is advisory and the render is misleading.
- [ ] `@coderabbitai configuration` has been run once on a pull request and its resolved output matches the committed file. This is the only way to confirm the file was accepted rather than discarded.
- [ ] `.bot-instructions/coderabbit-schema.json` is current, and the repo knows where it came from and how to refresh it. A stale copy rejects a newly valid file, and a copy carrying a JSON Schema keyword the validator does not implement blocks every render until the validator is updated.
- [ ] Integrations the repo wants (Linear, Jira) are authorized. The file names the tracker; the authorization is a UI step.

Once the file lands, everything the file controls moves into it. The dashboard is documentation at best, and a global override above it is the one thing that can still change what the file means.

## Qodo

- [ ] The Qodo app is installed on the repository and seats cover it.
- [ ] Which Qodo product this repo is on is known. `best_practices.md` is loaded automatically by Qodo Merge, the commercial product, and not by open-source PR-Agent; `[bot-instructions.bots] qodo_best_practices` should be `false` where the file would be inert.
- [ ] No `.pr_agent.toml` page exists in the repository wiki. A wiki page of that name applies without a commit and is invisible to version control and to the generator.
- [ ] No `pr-agent-settings` repository exists at the organization or project level carrying settings this repo does not expect.
- [ ] What other best-practices sources Qodo loads for this repo is known. Organization and mapped-repository files layer above the generated one and the generator cannot see them. Qodo recommends 800 lines per file and documents no limit on the total, so nothing here checks the total and the per-file number is this package's budget rather than a vendor cap.
- [ ] Before setting `[bot-instructions.bots] qodo_review_md`: the portal toggle under Configurations → Context, "REVIEW.md instructions", is on. Without it the file is inert, which is why the flag is set by hand after this line rather than inferred.

## Macroscope

- [ ] The Macroscope app is installed on the repository.
- [ ] Correctness review is enabled, and its detection mode and minimum comment severity are set. These have no repo-file equivalent.
- [ ] Maximum automatic runs per pull request is set.
- [ ] Spend caps are set: monthly, per pull request, and per review. Macroscope bills per review, and this package's exclusion list is what keeps a vendored tree from being paid for repeatedly.
- [ ] The generated `.macroscope/ignore.md` excludes what it names. The render writes the grammar Macroscope documents, one glob per line with `#` comments, and `references/limits.md` § Macroscope cites the page. Confirm once that the exclusions took effect.
- [ ] A repo that lints every tracked `*.md` excludes `.macroscope/ignore.md` from that lint and states why: the file is Macroscope's glob-per-line grammar, where `#` opens a comment, not a heading.

## If the repo's kendex.toml is a source catalog

- [ ] `[bot-instructions.exclusions] derive_render` reads the manifest kendex resolves, which in a repo whose `kendex.toml` declares `is_source_catalog = true` is the sibling `kendex-local.toml`. Confirm the rendered exclusion list actually names the repo's rendered skill trees. An empty list here is the failure this line exists to catch, not a repo with nothing to exclude.

## Glob dialect

- [ ] An exclusion took effect on Copilot, on Qodo, on Macroscope, and through CodeRabbit's minimatch. The dialect claims five engines read its patterns alike, and one can be tested from a repo carrying no third-party runtime: git's wildmatch, which is `git sparse-checkout`'s and which the vector harness measures. The `applyTo`, `[ignore]` and `include` matchers are unpublished and minimatch needs a Node runtime this package does not depend on, so this line is the only confirmation those four ever get.

## If the repo has its own guard over these files

- [ ] Every predicate that guard uses is at least as loose as the render's. A guard slicing `AGENTS.md` on `^## Code Review Rules$`, matching the directive line inside it, or matching a pointer sentence on one line of `.github/copilot-instructions.md`, is reading bytes this package writes; the render spec pins all three, and a repo adding a fourth predicate reconciles it before rendering rather than at adoption time.
- [ ] A guard pinning the reply form reads the pointed `code-review.md`, not the `AGENTS.md` region. The region carries the directive line and nothing else, so a guard still matching `Tracked: <PREFIX>-<n>` there reads the form as gone.
- [ ] `[bot-instructions.repo] tracker` is set wherever a guard pins the tracked reply form. Without it the render leaves the generic placeholder and the guard reads the form as gone.
- [ ] Retiring a bot whose file another check requires is a pointer move first, then the deletion. Where a repo's own gate reads `.github/copilot-instructions.md`, `[bot-instructions.bots] copilot = false` means moving what that gate reads before removing the file.

## The exclusion classes a repo starts from

Three classes are worth an exclusion in most repos. Only the first is derived; the other two are `[[bot-instructions.exclusions.path]]` entries a repo writes, because their paths differ per repo and because **an exclusion with no stated reason is indistinguishable from a mistake at the next read** — a shipped default nobody wrote a reason for is that mistake with nothing to catch it.

- **Render trees.** `[bot-instructions.exclusions] derive_render = true`. Derived from the writer inventory `.kendex-generated.json` and the manifest kendex resolves, so it follows a refresh instead of falling behind it, and it carries the one fixed reason `repo-toml.md` § `[bot-instructions.exclusions]` states.
- **Vendored trees this repo pins byte-for-byte.** One entry per tree. The reason names the upstream and says the fix lands there.
- **Lock files.** `Cargo.lock`, `package-lock.json`, `pnpm-lock.yaml` and the rest, wherever they sit. The reason is that a package manager writes them, so a finding on one is a finding about a dependency change rather than about the file. Exclude the file, not the manifest beside it.

Copy the second and third as entries rather than expecting the generator to know them, and let `exclusion-consistency`'s dead-exclusion clause tell you which ones this repo does not actually have.

## Excluding the render trees

- [ ] The exclusion set actually covers this repo's render trees. `render` fails when a destination the routing table marks as carrying the paths does not carry them, on every repo; what `[bot-instructions.exclusions] derive_render` decides is whether the set is derived from the install manifest or written by hand, so a repo deriving nothing still has to name its render trees in `[[bot-instructions.exclusions.path]]` for that check to have anything to enforce.

## After the checklist

After configuring the enabled capabilities, follow [workflows/add-repository.md § After the checklist](../workflows/add-repository.md#after-the-checklist).
