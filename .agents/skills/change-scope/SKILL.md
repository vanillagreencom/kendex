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
.agents/skills/change-scope/scripts/harness-only --event pull_request --base "$BASE" --head "$HEAD" --repo "$DIR"
```

`change-scope` takes an explicit repository, base and head and answers one class for that range: `render`, `trivial`, `micro`, `small` or `standard`. It reads its settings from the commit `--base` names, never from the judged tree or an author-writable field: a branch cannot choose the roots, test paths, ceilings or exclusions its own size is scored against. `harness-only` reads the changed paths and the docs set; `lib/branch-growth.sh` measures production, test and render-mirror lines over the same range, pairing a render with the source it mirrors and setting test paths aside by its built-in rule and `ORCH_SIZE_TEST_PATHS`; `references/narrow-change.conf` holds the path rules, the `instruction` floor and the `micro` and `small` production ceilings, and `HARNESS_CI_STANDARD_PATHS` adds the repository's own exclusions. `render` is proved by `kendex verify --json` over a private checkout of the head and the positions its passing rows own; `trivial` is a documentation-only diff within `HARNESS_CI_TRIVIAL_MAX_LINES`; a changed `kendex.settings.toml` or `.kendex/settings.toml` joins the trivial set where it changes only comments, blank lines and the `[env]` keys the base's `HARNESS_CI_TRIVIAL_SETTINGS` names, and a diff of such files alone has no ceiling; `small` is one subsystem, the first directory past a render root, with documentation and test paths belonging to none; an agent instruction file never answers below `small`; everything unproved is `standard`. stdout is one `change_class=<class>` line; stderr carries `changed-path:` lines, the reader's notes and one `class: class=<class> measured=true|false cause=<name> ...` line, where `measured=false` marks a fallback to `standard`, never a verdict; exit 2 is a wiring error with no verdict. Flags, settings and every cause: `change-scope --help`.

- Consume the class, keep the mapping. harness-ci maps it to lane selection and the queue-only route, reviewer to review depth, orch to a work tier; this package decides none of those.
- Read the class through `lib/change-scope.sh`: `change_scope_read BASE HEAD REPO STDERR_FILE` sets `CHANGE_SCOPE_CLASS` and `CHANGE_SCOPE_MEASURED`, `change_scope_rank` and `change_scope_floor` own the class order. A `measured=false` answer is a refusal to read, not a class; never treat it as one.
- Never read a class from a label, branch name, title or flag, and run the default branch's copy of the classifier against a pull request's tree: the branch can change this package too.
- A path rule, ceiling or threshold changes in `references/narrow-change.conf` alone, and its `# [boundary]` group names every file this package reads or runs to classify; `tests/narrow-boundary.test.sh` holds the two together.

## Shared refresh caller ownership

`lib/change-scope.sh` declares `HARNESS_CI_REFRESH_CALLER`, the adopted caller path shared by candidacy and ownership checks. Render candidacy, `harness-only --mode render-candidate`, permits that path without an inventory entry so CI can install the verifier; it grants no class. The classifier first accepts a recorded adopted caller owned by a passing verifier position. Without verifier ownership it fetches `refs/tags/<pin>` from the public catalog into a private store and runs that release's `refresh/lib/caller.py` with `python3 -I` to validate the caller's configuration and compare the normalized caller with the release template; only configuration blocks the release's adopter accepts may differ. A commit pin, any other byte difference, invalid configuration, an unavailable release, a missing caller module or a missing Python grants no fallback ownership. The fallback covers only the caller; other excluded paths still need a supporting verifier.

## Reading routes

| File | Read when |
|------|-----------|
| `references/narrow-change.conf` | Adding, moving or re-weighing a path rule, an instruction floor or a ceiling |
| `scripts/lib/branch-growth.sh` header | Measuring a branch from another package, or reading `BRANCH_GROWTH_CONTRACT` before calling across packages |
| `scripts/lib/kendex-env.sh` header | Reading what the base commit's settings files may hold |
