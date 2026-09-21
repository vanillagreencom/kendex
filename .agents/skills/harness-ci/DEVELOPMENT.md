# harness-ci development

Maintainer notes. Consumer docs: [README.md](README.md); the wiring rules: [SKILL.md](SKILL.md).

## Invariants

- `--no-renames` is fixed, never a flag. Rename detection emits only the post-image, so `git mv src/app.ts .agents/skills/x/app.ts` would list one harness path and nothing else, and the deletion of `src/app.ts` would go unjudged. Without it both paths are listed and the diff answers `false`.
- `pull_request` uses the merge base (`base...head`) because the base branch moves under an open PR. `push` and `merge_group` use the two endpoints (`base head`): a force-push leaves the `before` sha off the head's history, and a merge base there is a commit the push already discarded, so measuring from it reads a push that dropped product work as render-only. A merge group's base is an ancestor of its head by construction, so the two forms agree there.
- An empty changed-file set answers `false`, because it is also what a diff that read nothing looks like.
- Docs mode answers `false` when any changed path is outside the path set in `harness-only --help`. The `docs-only` suite enforces the set.
- The engine derives `.kendex-generated.json` from rendered artifact files, shared registration files, and instruction shims. It excludes in-place declarations. Pi carrier payloads do not enter the render model and remain source.
- Inventory membership is exact, never a folder prefix. A generated file adopted as source must be absent from the head inventory, which causes product checks to run. Deletions use the base inventory.
- A missing or invalid inventory runs every lane, including the commit that first installs the inventory. Inventory additions also run every lane before the new paths become trusted base data.
- `aggregate-needs` accepts a skipped job only when the classifier succeeded, its waiver is `true`, and the job is in the caller's explicit skippable set.
- `change-class` reads no diff range of its own: it calls `harness-only` for the changed-path set and for the generated-path ownership rules, and repeats that run's `changed-path:` lines as they stand and its verdict cause as a `harness-note:` line.
- A refresh that ADDS a rendered file gains an inventory entry, and `harness-only` refuses a gain, so the `render` class is out of reach for it and the diff takes the class its size earns. That refusal stands: `kendex verify` counts lock entries, and its exit status ignores the unmanaged content a hand-added inventory entry would become, so accepting a gain would let a branch name a product file as generated. Closing it needs a path-to-package map covering every kind, which the install record does not hold: `emitted.paths` records the installed roots of skills, commands and Pi extensions, and agents, hooks, MCP servers and plugins carry no recorded position at all. The `harness-note:` line is what tells an operator this happened.
- The `render` class reads nothing of orch's, and is the one class a checkout without that sibling can still reach. `trivial`, `micro` and `small` are all judged on orch's line count, and the last two also read its ceilings and its refused paths.
- A cross-package call into orch checks `BRANCH_GROWTH_CONTRACT` first. Each package is installed at its own revision, so the sibling can be older than the caller, and errexit is off inside `measure`: a missing function would be `command not found` on stderr and an extra argument would be dropped in silence.
- A harness instruction pointer (`CLAUDE.md`, `*/CLAUDE.md`) is refused every narrow class except `render`. Inside a diff the render proof covers it is a render like any other; anywhere else nothing re-rendered it and the shipped documentation set would take a root one for ordinary markdown.
- The `render` class needs `kendex verify` to report files checked and none failed, and needs the head install record to drop no entry its base holds. A clean exit alone is not proof: it also closes a run that checked nothing, in a checkout holding the committed inventory and no install record, so the counts on the closing line are read. That count is one per record entry, so a branch deleting an entry takes that package's files out of everything the proof measures, which is why the two records are compared before the proof runs. A diff of generated files alone that fails that proof answers `standard`; it never falls through to a measured class. No shipped kendex reaches the failed-count refusal on a zero exit today, since a run that checked nothing prints no counts line at all and a run with a failure exits non-zero; the refusal is the guard against a kendex that later reports failures beside a zero status, and its survival under mutation is that, not a gap.
- `kendex verify` runs a package's declared checker out of the tree it checks wherever the checkout carries kendex's arming record under a git directory. That checker is a file a pull request can change, so a checkout carrying a record is refused the `render` class rather than verified. The whole-project scope is also what makes the proof slow and what makes unrelated drift refuse the class; scoping it to the changed packages would need a path-to-package map covering every kind, and the lock's `emitted.paths` records installed roots for skills, commands and Pi extensions only.
- A changed configuration or instruction source refuses every narrow class. Those files decide what is rendered and what each judgement reads.
- The measured classes come from orch's `branch_size_classified`, which owns the production/test split and the render-mirror pairing `branch-size-check` judges an allowance by. `change-class` hands it the base endpoint the call named, so the lines are counted over the range the paths came from. Only `--event pull_request` reaches a measured class; every other event answers `render` or `standard`.
- The judged tree's configuration decides nothing. `branch_growth_render_roots_from_env` fixes the render roots from this process's environment before the measurement runs, so the tree's settings are never loaded: loading them would let the change under judgement choose the roots its own size is scored against, and would source the file its `KENDEX_ENV_FILE` names.
- A glob list is split with pathname expansion off. Splitting it under the default would replace a glob naming a real directory with the files under the caller's working directory, and the list would no longer be the list.

## Tests

`tests/` runs in kendex CI on every change to this repository; run one locally with `bash skills/harness-ci/tests/path-set.test.sh`.

| Suite | Covers |
| --- | --- |
| `path-set` | Writer-recorded paths, mixed diffs, carrier source, deletions, and unrecorded neighbors |
| `in-place` | Source adoption removes generated ownership |
| `rename-into-render` | The `git mv` into a render tree, and the control proving the flag is load-bearing |
| `event-ranges` | The force-push case, the moving base branch, merge groups |
| `fail-closed` | Unclassified events, unresolvable endpoints, an empty diff, a merge-base diff git refuses, a path git had to quote |
| `docs-only` | Documentation paths, excluded source paths, pull requests, merge groups, and the path-set must-fail control |
| `aggregate-needs` | Successful dependencies, authorized skips, refused results, invalid input, and must-fail controls for classifier success, dependency success, the waiver, and skippable membership |
| `wiring-errors` | Exit 2 on bad calls, a flag where a value belongs included; `--output` and `$GITHUB_OUTPUT` behaviour |
| `wiring-shapes` | Every shape in `references/wiring.md` keeps each expression on one line, orders the push endpoints, names the shipped script path, and steps its indentation by two |
| `change-class` | One row per class and per boundary, the author-writable fields that assert nothing, the wiring outputs, both trivial settings, and the must-fail control where a classifier trusting the inventory passes a hand edit inside a render |

The `change-class` suite's last section installs and refreshes a real consumer with a real `kendex` rather than a double, which is the only way its `render` rows carry the claim they name. Without a `kendex` on PATH that section skips itself, so the `rest` shard of `.github/workflows/skill-tests.yml` installs one on its Linux leg and exports `HARNESS_CI_REQUIRE_KENDEX=1`, which turns that skip into a failure there. The fixture builds its own catalog as a local git repository and fetches it into a sandbox `HOME`, so nothing needs a primed source mirror. The macOS leg keeps the skip: it is already that shard's slowest leg, and the rows judge the classifier rather than the platform, so one leg proves them.

`tools/bash32-lint` checks the shipped script for Bash 4+ syntax, because consumer runners include macOS system Bash 3.2.
