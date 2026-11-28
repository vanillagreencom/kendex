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
      purpose: Read a changed manifest's sources, and compare an adopted refresh caller with its released template
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

`change-scope` answers one class for an explicit repository, base and head. `change-scope launch` answers the class a work item launches at, before its branch exists. `harness-only` reads the changed paths and answers whether a diff may skip a family of CI checks. `change-scope --help` states every flag, the rule behind each class and every setting except `HARNESS_CI_DOCS_PATHS`, which `harness-only --help` states with its own flags. The `class:` line on `change-scope`'s stderr names the cause of its answer.

## Classes

The classes, narrowest first, are `render`, `trivial`, `micro`, `small` and `standard`. The first class a rule proves wins. Anything unproved is `standard`.

- `render`: a passing row of `kendex verify --scope project --json`, run in a private checkout of the head, owns every surviving changed path. The caller proof in § Shared refresh caller ownership can own a path instead.
- `trivial`: by default, a range confined to kendex manifests, JSON settings files and Markdown files takes this class at any size, except a harness file that registers hooks, permissions or MCP servers, at any depth (`.claude/settings.json`, `.codex/hooks.json`, `.codex/config.toml`, `.github/hooks/*.json`, `.pi/kendex/hooks.json`, `.mcp.json`, `opencode.json` and the rest of the registry list `scripts/lib/change-scope.sh` holds, and `.gemini/settings.json`), a changed `[sources]` table in `kendex.toml` or `kendex-local.toml`, a changed `.kendex-lock.json`, and a path `HARNESS_CI_STANDARD_PATHS` names. See `change-scope --help` for the supported overrides.
  - The kendex manifests are `kendex.toml`, `kendex-local.toml`, `kendex.settings.toml` and `.kendex/settings.toml`. A JSON settings file is one named `settings.json`, `settings.jsonc`, `settings.local.json` or `settings.local.jsonc`, at any path. The Markdown is the docs set, every `.md` or `.markdown` file plus `docs/` and `changelog.d/`.
  - Where `HARNESS_CI_TRIVIAL_PATHS` is set, the repository's own globs replace the docs set.
- `micro`: production additions within `micro_max_production` in `references/narrow-change.conf`.
- `small`: one subsystem, production additions within `small_max_production`. A path's subsystem is its first directory, after a leading render root is removed. The render roots are `ORCH_SIZE_RENDER_ROOTS`, by default `.agents`, `.claude`, `.codex` and `.pi`. So `skills/orch/SKILL.md`, `.agents/skills/orch/SKILL.md` and `skills/reviewer/scripts/review-depth` are all subsystem `skills`. Test, fixture and docs-set paths, kendex manifests and JSON settings files belong to no subsystem.
- `standard`: everything else, and every diff the classifier cannot read.

`scripts/lib/branch-growth.sh` measures production, test, render-mirror and paired dependency lock lines over the range. It sets test paths aside by its built-in rule and `ORCH_SIZE_TEST_PATHS`. `references/narrow-change.conf` holds the path rules, including the lock pairing that sends a diff through the `small` size and subsystem checks. `HARNESS_CI_STANDARD_PATHS` adds the repository's own exclusions.

A diff that earns `trivial` or `micro` and removes test protection answers `small`. The classifier counts the list's `case`, `skip` and `selection` lines over the whole range. A failed read of that protection answers `standard`.

Every setting comes from the caller's environment or the commit `--base` names, as `change-scope --help` states for each and `harness-only --help` states for `HARNESS_CI_DOCS_PATHS`, never from the judged tree or an author-writable field. A branch cannot choose the roots, test paths, ceilings or exclusions its own size is scored against.

## Reading the answer

- stdout is one line, `change_class=<class>`.
- stderr ends with one `quick-proof: proved=true|false` line and then one `class:` line that carries `measured=true|false`.
- `measured=false` marks a fallback to `standard` because the classifier could not read something. It is a refusal to read, never a class.
- `quick-proof: proved=true` needs `--event pull_request`, an unset or empty `HARNESS_CI_TRIVIAL_PATHS`, and a `trivial` answer whose every changed path is a kendex manifest, a JSON settings file or a `.md` or `.markdown` file. Act on the literal `true` alone. An absent line proves nothing.
- Exit 2 is a wiring error, with no class.

## Launch arm

`change-scope launch` classifies a work item from the inputs that name a class: a production estimate, the item body's `Expected delta` line, the paths it names, a class the item already holds and a range. It reads them in that order. The widest class wins. The first input that names it is the cause.

The range input takes the class the classifier answers for the range through `change_scope_read`, the reading review depth takes. A range the classifier answers `render` or `trivial` reads as `micro` at any size, and any other range past `small_max_production` is `standard`. The cause is `branch-class class=C rule=R`, with the classifier's class and cause. A classifier that cannot answer reads `standard`, `measured=false`, cause `branch-class-unreadable`, and the arm repeats the classifier's stderr. A names-only inventory change under rendered roots is left to the classifier. It answers `standard` for a range that adds a catalog source, since its render proof owns no catalog source, and reads a removal by its size. A range that changes the lock is `standard` whatever the classifier answers.

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
| `references/narrow-change.conf` | Adding, moving or re-weighing a path rule, a protection marker or a ceiling |
| `scripts/lib/branch-growth.sh`, the comment above `BRANCH_GROWTH_CONTRACT` | Calling the branch measurement from another package |
| `scripts/lib/kendex-env.sh` header | Reading what the base commit's settings files may hold |
