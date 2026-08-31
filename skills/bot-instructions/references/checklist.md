# Per-repo settings checklist

Every bot here has at least one setting that lives in a web UI and cannot be
expressed in any file the repo contains. Skip one and the repo looks fully
configured while a bot reviews nothing, or reviews with the wrong scope, and no
render or validator can tell.

Work this once per repo, in the pull request that adds
`bot-instructions.toml`. Record the outcome of each line in that repo, next to
the TOML, so the next person can tell a deliberate `false` from an unanswered
question.

A bot capability whose row here is unanswered should be `false` in `[bots]`. A
`true` flag renders files that reach nothing, which is worse than no files at
all.

None of this state is machine-readable from the repo, and an administrator can
change any of it without touching the repo. Every check here can keep passing
after a bot has been switched off in a settings page nobody looked at, so the
last section's smoke test is what actually confirms the set.

## GitHub Copilot code review

- [ ] Copilot is enabled for the repository, under an org or enterprise plan
      that covers code review.
- [ ] Automatic review is enabled, either per repository or through an
      organization ruleset requiring Copilot as a reviewer. Without it the
      instruction files load only when someone requests a review by hand.
- [ ] Custom instructions are enabled for code review in the repository's
      Copilot settings. The files exist regardless; this toggle decides whether
      review reads them.
- [ ] Content exclusion paths are set, if any are wanted. Settings → Copilot →
      Content exclusion, in YAML fnmatch form. This is the only exclusion
      mechanism Copilot has, and it is not a repo file. Anything in
      `[[exclusions.path]]` that must also be invisible to Copilot is entered
      here by hand.
- [ ] The organization's runner-type setting is understood. An org admin can
      set a default runner type across all repositories and lock it, overriding
      per-repo configuration.

## Codex code review

- [ ] The Codex GitHub app is installed on the repository.
- [ ] Code review is enabled for this repository at
      <https://chatgpt.com/codex/settings/code-review>. Requires push or admin
      permission on the repo.
- [ ] Automatic reviews are on, or the team knows reviews come only from an
      `@codex review` comment.
- [ ] Security-review scope is set, if the repo wants it.

Nothing else about Codex is configurable from the repo. `AGENTS.md` § Code
Review Rules is its entire instruction surface, and it has no file-based
exclusion mechanism at all, which is why the rendered section carries every
doctrine block rather than a subset.

## CodeRabbit

- [ ] The CodeRabbit app is installed and the repository is enabled in the
      organization.
- [ ] No organization or workspace global override is set. Those outrank the
      repo file, and a repo cannot see them. If one exists, everything in
      `.coderabbit.yaml` is advisory and the render is misleading.
- [ ] `@coderabbitai configuration` has been run once on a pull request and its
      resolved output matches the committed file. This is the only way to
      confirm the file was accepted rather than discarded.
- [ ] The vendored schema copy the validator reads is current, and the repo
      knows where it came from and how to refresh it. A stale copy rejects a
      newly valid file, and a copy carrying a JSON Schema keyword the validator
      does not implement blocks every render until the validator is updated.
- [ ] Integrations the repo wants (Linear, Jira) are authorized. The file names
      the tracker; the authorization is a UI step.

Once the file lands, everything the file controls moves into it. The dashboard
is documentation at best, and a global override above it is the one thing that
can still change what the file means.

## Qodo

- [ ] The Qodo app is installed on the repository and seats cover it.
- [ ] Which Qodo product this repo is on is known. `best_practices.md` is
      loaded automatically by Qodo Merge, the commercial product, and not by
      open-source PR-Agent; `[bots] qodo_best_practices` should be `false`
      where the file would be inert.
- [ ] No `.pr_agent.toml` page exists in the repository wiki. A wiki page of
      that name applies without a commit and is invisible to version control
      and to the generator.
- [ ] No `pr-agent-settings` repository exists at the organization or project
      level carrying settings this repo does not expect.
- [ ] No other best-practices source is loaded for this repo. Qodo caps
      accumulated best-practices content at 2,000 lines across every source,
      and the generator can only see the one file it writes.
- [ ] Before setting `[bots] qodo_review_md`: the portal toggle under
      Configurations → Context, "REVIEW.md instructions", is on. Without it the
      file is inert, which is why the flag is set by hand after this line
      rather than inferred.

## Macroscope

- [ ] The Macroscope app is installed on the repository.
- [ ] Correctness review is enabled, and its detection mode and minimum comment
      severity are set. These have no repo-file equivalent.
- [ ] Maximum automatic runs per pull request is set.
- [ ] Spend caps are set: monthly, per pull request, and per review. Macroscope
      bills per review, and this package's exclusion list is what keeps a
      vendored tree from being paid for repeatedly.
- [ ] The generated `.macroscope/ignore.md` excludes what it names. Macroscope
      documents no grammar for that file, so the render keeps every non-pattern
      line inside an HTML comment on the assumption that anything else would be
      read as a pattern. Confirm once that the exclusions took effect.

## If the repo has its own guard over these files

- [ ] Every predicate that guard uses is at least as loose as the render's.
      A guard slicing `AGENTS.md` on `^## Code Review Rules$`, or matching a
      pointer sentence on one line of `.github/copilot-instructions.md`, is
      reading bytes this package writes; the render spec pins both, and a repo
      adding a third predicate reconciles it before rendering rather than at
      adoption time.
- [ ] `[repo] tracker` is set wherever a guard pins the tracked reply form.
      Without it the render leaves the generic placeholder and the guard reads
      the form as gone.
- [ ] Retiring a bot whose file another check requires is a pointer move first,
      then the deletion. kendex's guard fails when
      `.github/copilot-instructions.md` is absent, so `[bots] copilot = false`
      there means moving what that guard reads before removing the file.

## If the repo's gate reads bot output

- [ ] `bot-instructions.toml`, the doctrine source, and every generated path
      are policy paths in the repo's gate: a push touching one invalidates
      review evidence gathered before it.
- [ ] A pull request touching a policy path needs a trusted human approval. Bot
      evidence gathered under head-branch policy that same pull request wrote is
      not evidence.
- [ ] The CI lane running `check` uses this package's copy from the default
      branch, not the pull request's checkout.

## After the checklist

Open one pull request that touches a file each bot should comment on, and
confirm each enabled bot posts. A bot that stays silent on a deliberately
imperfect diff has a settings problem, not an instructions problem, and no
amount of re-rendering fixes it. This is the only step that tests the settings
above rather than trusting the record of them.
