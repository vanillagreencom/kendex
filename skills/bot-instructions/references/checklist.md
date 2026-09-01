# Per-repo settings checklist

## Adding a repo

Two passes. The order is not a preference — three rules fix it, and a sequence
that ignores them writes a TOML that does not validate or a render that stops.

**What those rules require, since everything below follows from them.**

*From `toml-schema`'s cross-flag clauses.* A `[[surface]]` set needs at least
one of `copilot`, `coderabbit`, `macroscope` or `qodo_best_practices` on,
because those four are every route surface text has. `copilot` or `coderabbit`
needs `codex`, because the `AGENTS.md` section is where both get most of their
doctrine. `qodo_best_practices` and `qodo_review_md` need `qodo`.

*From `adopt`'s own rule.* It takes a file or region over only for a capability
that is on.

Those two give **capability-dependent content lands with its capability**, and
nothing that depends on a flag is written before the flag.

*From `agents-section`'s nested-`AGENTS.md` clause.* It rejects a nested
`AGENTS.md` carrying a `## Code Review Rules` section, it is the one clause no
flag gates, and it runs against the repo before every write. So it is invisible
to the flag reasoning above and constrains the sequence anyway: a repo holding
such a section cannot complete **any** render, including a pass-one render with
every flag off. Clearing it is therefore a pass-one prerequisite rather than
part of the `codex` capability's own pass.

**Pass one, the repo-wide TOML.** `[repo]`, `[exclusions]`, `[cadence]`,
`[tone]`, `[budgets]` and any `[doctrine.*]` overrides, with every `[bots]` flag
false and no `[[surface]]` entries.

1. Read the repo's existing hand-written bot files now and plan where their
   claims go: which become `[[surface]]` entries, which become
   `[doctrine.append]`, which will not fold and stay hand-written as policy
   paths. Write the repo-wide tables; leave the surfaces for the pass that turns
   on a bot able to read them.
2. Clear any nested `AGENTS.md` carrying a `## Code Review Rules` section. Fold
   what it holds into `[doctrine.append]` or a `[[surface]]` and delete the
   section, or move the section out of an `AGENTS.md`. The generator writes only
   the root one, and `agents-section` rejects a nested one unconditionally, so
   this is what a pass-one render stops on if it is skipped. Its content is not
   lost: it lands in the TOML written in step 1.
3. Do not run `adopt` here. Nothing can be adopted for a capability that is off,
   so it would report nothing on exactly the repo this planning is for.
4. Run `render`. With step 2 done it writes nothing and says so, because every
   flag is off; that no-op is the staging point, not a finished install, and the
   existing bot files are still the repo's own and still what the bots read.
   With step 2 skipped it does not write nothing — it stops on the nested
   section before the write and names the file, which is the clause doing its
   job rather than a failure of the sequence.

**Pass two, per capability.** Enable `codex` first if this repo wants `copilot`
or `coderabbit`, and `qodo` before its two sub-flags. Then, one capability at a
time, finishing each before starting the next so a failure names the bot that
caused it:

5. Work that capability's settings section below.
6. Do its prerequisite, where it has one. `codex` needs a `## Code Review Rules`
   heading added to `AGENTS.md` by hand, since the generator never adds it.
   `coderabbit` needs CodeRabbit's published schema at
   `.bot-instructions/coderabbit-schema.json`; no verb writes it and
   `coderabbit-schema` fails without it, deliberately, because a validator that
   skipped on a missing schema would be silent for the life of the repo.
   `qodo_review_md` needs the portal toggle already on.
7. Set the flag. With the first of `copilot`, `coderabbit`, `macroscope` or
   `qodo_best_practices`, add the `[[surface]]` entries planned in step 1 — they
   are legal from that moment and were not before.
8. Run `adopt`. It can now take over that capability's generated paths, the
   `AGENTS.md` region the heading opened included, and it names every file and
   region it takes plus every repo-root or `.github/` markdown file those files
   point at. That second list is where a repo-wide hand-written reviewer file
   shows up. Read both against the TOML: a claim in one of those files that the
   TOML does not carry is about to be deleted, or to go on steering reviews from
   outside the package.
9. Run `render`, then read the diff. Doctrine text appearing for the first time
   is expected; a repo-specific claim disappearing means it never made it into
   the TOML.
10. Run `check`. Then repeat from step 5 for the next capability.

**Walked end to end, for a repo that arrives with hand-written bot files.**
Pass one clears any nested `## Code Review Rules` section into the TOML, then
commits a TOML that validates and a render that writes nothing, leaving those
files untouched and still authoritative. The first capability's pass sets `codex`,
opens the `AGENTS.md` region, adopts it, and renders the section. The next sets
`copilot`, adds the surfaces, and adopts `.github/copilot-instructions.md` and
the `.instructions.md` names those surfaces produce — a hand-written file in
that directory under a name no surface produces is left alone, which is correct
and stays the repo's own. Each later capability adopts and renders only its own
paths. The install is finished when every capability the repo wants is on,
`check` is clean, and the smoke test at the end of this file has seen each
enabled bot comment. A repo that stops after pass one has staged the work, not
done it.

## The settings

Every bot here has at least one setting that lives in a web UI and cannot be
expressed in any file the repo contains. Skip one and the repo looks fully
configured while a bot reviews nothing, or reviews with the wrong scope, and no
render or validator can tell.

Work one capability's section at a time, as the settings step of the sequence
above, and record each line's outcome in the repo beside the TOML so the next
person can tell a deliberate `false` from an unanswered question.

A capability whose section here is unanswered stays `false` in `[bots]`. A
`true` flag renders files that reach nothing, which is worse than no files at
all — and a section answered but never followed by setting the flag leaves the
reverse, a bot enabled at the vendor reading nothing this package wrote.

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
- [ ] `.bot-instructions/coderabbit-schema.json` is current, and the repo knows
      where it came from and how to refresh it. A stale copy rejects a
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
- [ ] What other best-practices sources Qodo loads for this repo is known.
      Organization and mapped-repository files layer above the generated one and
      the generator cannot see them. Qodo recommends 800 lines per file and
      documents no limit on the total, so nothing here checks the total and the
      per-file number is this package's budget rather than a vendor cap.
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

## If the repo's kendex.toml is a source catalog

- [ ] `[exclusions] derive_render` reads the manifest kendex resolves, which in
      a repo whose `kendex.toml` declares `is_source_catalog = true` is the
      sibling `kendex-local.toml`. Confirm the rendered exclusion list actually
      names the repo's rendered skill trees. An empty list here is the failure
      this line exists to catch, not a repo with nothing to exclude.

## Glob dialect

- [ ] An exclusion took effect on Copilot, on Qodo and on Macroscope. The
      dialect claims five engines read its patterns alike, and only two can be
      tested from a repo: CodeRabbit's minimatch and real `git sparse-checkout`.
      The `applyTo`, `[ignore]` and `include` matchers are unpublished, so this
      line is the only confirmation those three ever get.

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

## Excluding the render trees

- [ ] The exclusion set actually covers this repo's render trees. `render` fails
      when it does not, but only where `[exclusions] derive_render` is on, so a
      repo deriving nothing checks this by reading the rendered `path_filters`
      against `.agents/`.
- [ ] Enforcement for Codex, Copilot and Qodo comes from the merge gate, not
      from here. Those three receive the paths as an instruction and may comment
      on them anyway; a gate that passes a render-only diff needs no bot to
      cooperate, which is the only thing that makes "a render-only diff opens no
      bot rounds" true rather than requested. CodeRabbit and Macroscope subtract
      for real and need nothing from the gate.

## If the repo's gate reads bot output

- [ ] Every path in SKILL.md § A pull request changing its own review's policy
      set is a policy path in the repo's gate: a push touching one invalidates
      review evidence gathered before it. Work from that list rather than from a
      copy of it — it is longer than the obvious four, and a copy here would
      drift from it. In this repo it is what feeds
      `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which the gate reads from the default
      branch and so cannot be widened by the pull request under judgment.
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
