---
name: change-scope
description: "Load to classify a diff's change class, or to read the shared path rules and branch measurement a tier, review depth or CI selection rests on."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
compatibility: "Requires these commands on PATH: git, jq"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Change Scope

```bash
.agents/skills/change-scope/scripts/change-scope --event pull_request --base "$BASE" --head "$HEAD" --repo "$DIR"
.agents/skills/change-scope/scripts/change-scope launch --body "$BODY_FILE" --floor small --path "$PATH_NAMED"
.agents/skills/change-scope/scripts/harness-only --event pull_request --base "$BASE" --head "$HEAD" --repo "$DIR"
```

`change-scope` answers one class for an explicit repository, base and head. `change-scope launch` answers the class a work item launches at, before its branch exists. `harness-only` reads the changed paths and answers whether a diff may skip a family of CI checks. `change-scope --help` states every flag, the rule behind each class and every setting except `HARNESS_CI_DOCS_PATHS`, which `harness-only --help` states with its own flags. The `class:` line on `change-scope`'s stderr names the cause of its answer.

## Classes

The classes, narrowest first, are `render`, `trivial`, `micro`, `small` and `standard`. The first class a rule proves wins. Anything unproved is `standard`.

- `render`: a passing row of `kendex verify --scope project --json`, run in a private checkout of the head, owns every surviving changed path. The caller proof in § Shared refresh caller ownership can own a path instead.
- `trivial`: every changed path is in the docs set, and the diff is within `HARNESS_CI_TRIVIAL_MAX_LINES`. Where `HARNESS_CI_TRIVIAL_PATHS` is set, the repository's own globs replace the docs set. A changed `kendex.settings.toml` or `.kendex/settings.toml` that the settings admission in `change-scope --help` admits joins the set. A diff of admitted settings files alone has no line ceiling.
- `micro`: production additions within `micro_max_production` in `references/narrow-change.conf`.
- `small`: one subsystem, production additions within `small_max_production`. A path's subsystem is its first directory, after a leading render root is removed. The render roots are `ORCH_SIZE_RENDER_ROOTS`, by default `.agents`, `.claude`, `.codex` and `.pi`. So `skills/orch/SKILL.md`, `.agents/skills/orch/SKILL.md` and `skills/reviewer/scripts/review-depth` are all subsystem `skills`. Test, fixture and docs-set paths belong to no subsystem.
- `standard`: everything else, and every diff the classifier cannot read.

`scripts/lib/branch-growth.sh` measures production, test and render-mirror lines over the range. It sets test paths aside by its built-in rule and `ORCH_SIZE_TEST_PATHS`. `references/narrow-change.conf` holds the path rules that refuse the narrow classes, the `instruction` globs, the protection markers and the two ceilings. `HARNESS_CI_STANDARD_PATHS` adds the repository's own exclusions.

Three floors lift a diff that earns `trivial` or `micro` to `small`:

- An admitted consumer manifest. `change-scope --help` states its admission.
- A changed agent instruction file, one an `instruction` glob (`AGENTS.md`, `SKILL.md`) matches.
- A diff that removes test protection. The classifier counts the list's `case`, `skip` and `selection` lines over the whole range. A failed read of that protection answers `standard`.

Every setting comes from the caller's environment or the commit `--base` names, as `change-scope --help` states for each and `harness-only --help` states for `HARNESS_CI_DOCS_PATHS`, never from the judged tree or an author-writable field. A branch cannot choose the roots, test paths, ceilings or exclusions its own size is scored against.

## Reading the answer

- stdout is one line, `change_class=<class>`.
- stderr ends with one `quick-proof: proved=true|false` line and then one `class:` line that carries `measured=true|false`.
- `measured=false` marks a fallback to `standard` because the classifier could not read something. It is a refusal to read, never a class.
- `quick-proof: proved=true` needs `--event pull_request`, an unset or empty `HARNESS_CI_TRIVIAL_PATHS`, and a `trivial` answer whose every changed path is Markdown of the docs set or an admitted settings file. Act on the literal `true` alone. An absent line proves nothing.
- Exit 2 is a wiring error, with no class.

## Launch arm

`change-scope launch` classifies a work item from the inputs that name a class: a production estimate, the item body's `Expected delta` line, the paths it names, a class the item already holds and a range. It reads them in that order. The widest class wins. The first input that names it is the cause.

The range input takes the class the classifier answers for the range through `change_scope_read`, the reading review depth takes. The range's production lines count, so a range past `small_max_production` is `standard`. `render` and `trivial` read as `micro`. The cause is `branch-class class=C rule=R`, with the classifier's class and cause. A classifier that cannot answer reads `standard`, `measured=false`, cause `branch-class-unreadable`, and the arm repeats the classifier's stderr. A names-only inventory change under rendered roots is left to the classifier. It answers `standard` for a range that adds a catalog source, since its render proof owns no catalog source, and reads a removal by its size. A range that changes the lock is `standard` whatever the classifier answers.

`HARNESS_CI_STANDARD_PATHS` comes from the main checkout of `--repo`, never from a linked worktree's own settings. stdout is `change_class=micro|small|standard`. The arm prints no `quick-proof:` line.

## Rules

- Consume the class and keep the mapping. harness-ci maps the class to lane selection and the queue-only route, reviewer to review depth, orch to a work tier. This package decides none of those.
- Read the class through `scripts/lib/change-scope.sh`. `change_scope_read BASE HEAD REPO STDERR_FILE` sets `CHANGE_SCOPE_CLASS`, `CHANGE_SCOPE_MEASURED` and `CHANGE_SCOPE_RULE`, the cause fields of the last `class:` line. `change_scope_rank` and `change_scope_floor` own the class order.
- Never read a class from a label, branch name, title or flag.
- A caller that acts on the class without review runs the default branch's copy of the classifier against the pull request's tree. The branch can change this package too.
- Change a path rule, ceiling or threshold in `references/narrow-change.conf` alone.

## Shared refresh caller ownership

`scripts/lib/change-scope.sh` declares `HARNESS_CI_REFRESH_CALLER`, the adopted refresh caller path. Render candidacy and the render proof both read it.

- Render candidacy, `harness-only --mode render-candidate`, permits that path without an inventory entry, so CI can install the verifier. Candidacy grants no class.
- The render proof first takes the caller's ownership from a passing verifier position.
- Without one, the proof fetches `refs/tags/<pin>` from the public catalog into a private store. It runs that release's `refresh/lib/caller.py` with `python3 -I`. The module validates the caller's configuration and compares the normalized caller with that release's `refresh/kendex-refresh.yml`. Only the configuration blocks the release accepts may differ.
- None of these grants ownership: a commit pin, any other byte difference, an invalid configuration, an unavailable release, a missing caller module or a missing `python3`.
- The fallback covers the caller alone. Every other excluded path still needs a passing verifier position.

## Reading routes

| File | Read when |
|------|-----------|
| `references/narrow-change.conf` | Adding, moving or re-weighing a path rule, an instruction glob, a protection marker or a ceiling |
| `scripts/lib/branch-growth.sh`, the comment above `BRANCH_GROWTH_CONTRACT` | Calling the branch measurement from another package |
| `scripts/lib/kendex-env.sh` header | Reading what the base commit's settings files may hold |
