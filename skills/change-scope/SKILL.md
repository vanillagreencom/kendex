---
name: change-scope
description: "Load to classify a diff's change class, or to read the shared path rules and branch measurement a tier, review depth or CI selection rests on."
summary: "The shared change classifier: one class per diff range, from the trusted base commit's settings, the shared path rules, the branch measurement and the render proof, consumed by CI selection, review depth and tier admission through their own mappings."
license: MIT
user-invocable: true
dependencies:
  commands:
    - command: git
      purpose: Read the judged range, the base commit's settings and the private proof checkout
    - command: jq
      purpose: Read the verify document the render class is proved from
    - command: kendex
      purpose: Prove the render class by re-rendering the head
      optional: true
    - command: python3
      purpose: Compare an adopted refresh caller with its released template
      optional: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation, review]
---

# Change Scope

```bash
.agents/skills/change-scope/scripts/change-scope --event pull_request --base "$BASE" --head "$HEAD" --repo "$DIR"
.agents/skills/change-scope/scripts/change-scope launch --body "$BODY_FILE" --floor small --path "$PATH_NAMED"
.agents/skills/change-scope/scripts/harness-only --event pull_request --base "$BASE" --head "$HEAD" --repo "$DIR"
```

`change-scope` answers one class for an explicit repository, base and head. `change-scope launch` answers the class a work item launches at, before its branch exists. `harness-only` reads the changed paths and answers whether a diff may skip a family of CI checks. Every flag, setting and cause is in `change-scope --help` and `harness-only --help`.

## Classes

The classes, narrowest first: `render`, `trivial`, `micro`, `small`, `standard`. The first that a rule proves wins; anything unproved is `standard`.

- `render`: every surviving changed path is owned by a passing row of `kendex verify --scope project --json`, run in a private checkout of the head, or by the caller proof in § Shared refresh caller ownership.
- `trivial`: every changed path is in the docs set, and the diff is within `HARNESS_CI_TRIVIAL_MAX_LINES`. `HARNESS_CI_TRIVIAL_PATHS`, where set, replaces the docs set with the repository's own globs. A changed `kendex.settings.toml` or `.kendex/settings.toml` joins the set where it changes only comments, blank lines and the `[env]` keys the base admits through installed `# ci: unread` declarations and its `HARNESS_CI_TRIVIAL_SETTINGS` adjustments. A diff of admitted settings files alone has no line ceiling.
- `micro`: production additions within `micro_max_production` in `references/narrow-change.conf`.
- `small`: one subsystem, production additions within `small_max_production`. A path's subsystem is its first directory past a render root. Test, fixture and docs-set paths belong to no subsystem.
- `standard`: everything else, and every diff the classifier cannot read.

`lib/branch-growth.sh` measures production, test and render-mirror lines over the range. It sets test paths aside by its built-in rule and `ORCH_SIZE_TEST_PATHS`. `references/narrow-change.conf` holds the path rules that refuse the narrow classes, the `instruction` globs, the protection markers and the two ceilings. `HARNESS_CI_STANDARD_PATHS` adds the repository's own exclusions.

Three floors lift a diff that earns `trivial` or `micro` to `small`:

- An admitted consumer manifest answers `cause=consumer-manifest`; `change-scope --help` states its admission.
- A changed agent instruction file, an `instruction` glob (`AGENTS.md`, `SKILL.md`), answers `cause=instruction-file`.
- A diff that removes test protection answers `cause=protection-removed`, by the list's `case`, `skip` and `selection` lines counted over the whole range. A failed read of that protection answers `standard`, `cause=protection-unreadable`.

Every setting comes from the commit `--base` names, never from the judged tree or an author-writable field. A branch cannot choose the roots, test paths, ceilings or exclusions its own size is scored against.

## Reading the answer

- stdout is one line, `change_class=<class>`.
- stderr carries the `changed-path:` lines, the readers' notes, one `quick-proof: proved=true|false` line and then one `class: class=<class> measured=true|false cause=<name> ...` line.
- `measured=false` marks a fallback to `standard` because something could not be read. It is a refusal to read, never a class.
- `quick-proof: proved=true` holds only on `--event pull_request`, with `HARNESS_CI_TRIVIAL_PATHS` unset or empty, for a `trivial` answer whose every changed path is Markdown of the docs set or an admitted settings file. Act on the literal `true` alone; an absent line proves nothing.
- Exit 2 is a wiring error, `wiring-error: cause=...`, with no class.

## Launch arm

`change-scope launch` classifies a work item from the inputs that name a class. The widest class wins, and the first input that names it is the cause.

- `--production N`: an estimate of added production lines, judged against the two ceilings.
- `--body FILE`: the item body's `Expected delta` line, which floors the estimate. A body with neither a valid delta nor an estimate is `standard`. A malformed delta prints `launch-warning: cause=invalid-delta` and reads as none.
- `--floor CLASS`, repeatable: a class the item already holds, at or above `micro`. Any other class is a wiring error, `cause=invalid-floor floor=<class>`.
- `--path PATH`, repeatable: judged by the shared path rules' launch phase. No render is proved, and an unmatched path changes nothing.
- `--base REF --head REF`, given together: the range's changed paths, the range itself `micro`, and a removal of test protection `small`.

`HARNESS_CI_STANDARD_PATHS` comes from the main checkout of `--repo`, never from a linked worktree's own settings. stdout is `change_class=micro|small|standard`; stderr ends with `class: class=<class> measured=true|false delta=<n>|- cause=<cause>`. The arm prints no `quick-proof:` line.

## Rules

- Consume the class and keep the mapping. harness-ci maps it to lane selection and the queue-only route, reviewer to review depth, orch to a work tier. This package decides none of those.
- Read the class through `lib/change-scope.sh`. `change_scope_read BASE HEAD REPO STDERR_FILE` sets `CHANGE_SCOPE_CLASS` and `CHANGE_SCOPE_MEASURED`; `change_scope_rank` and `change_scope_floor` own the class order. Never treat `measured=false` as a class.
- Never read a class from a label, branch name, title or flag. A caller that acts on the class without review runs the default branch's copy of the classifier against the pull request's tree, because the branch can change this package too.
- Change a path rule, ceiling or threshold in `references/narrow-change.conf` alone. Its `# [boundary]` group names every file this package reads or runs to classify, and `tests/narrow-boundary.test.sh` holds the group to the classifier's `measures-with` lines.

## Shared refresh caller ownership

`lib/change-scope.sh` declares `HARNESS_CI_REFRESH_CALLER`, the adopted refresh caller path that candidacy and ownership both read.

- Render candidacy, `harness-only --mode render-candidate`, permits that path without an inventory entry so CI can install the verifier. It grants no class.
- The render proof first takes the caller's ownership from a passing verifier position.
- Without that, it fetches `refs/tags/<pin>` from the public catalog into a private store. It runs that release's `refresh/lib/caller.py` with `python3 -I` to validate the caller's configuration and compare the normalized caller with the release template. Only the configuration blocks the release accepts may differ.
- A commit pin, any other byte difference, an invalid configuration, an unavailable release, a missing caller module or a missing `python3` grants no ownership.
- The fallback covers the caller alone. Every other excluded path still needs a passing verifier position.

## Reading routes

| File | Read when |
|------|-----------|
| `references/narrow-change.conf` | Adding, moving or re-weighing a path rule, an instruction glob, a protection marker or a ceiling |
| `scripts/lib/branch-growth.sh` header | Measuring a branch from another package, or reading `BRANCH_GROWTH_CONTRACT` before calling across packages |
| `scripts/lib/kendex-env.sh` header | Reading what the base commit's settings files may hold |
