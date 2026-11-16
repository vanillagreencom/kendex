# change-scope development

Bash, `git` and `jq`. The render rows need a `kendex` on PATH, and the caller fallback needs `python3`. The contracts are [SKILL.md](SKILL.md), `change-scope --help` and `harness-only --help`; the comments beside each rule in `scripts/` state why it holds.

## Test

```bash
bash skills/change-scope/tests/narrow-change.test.sh   # one suite; every suite is tests/*.test.sh
```

kendex's `.github/workflows/skill-tests.yml` runs every suite on each change to this repository. It runs `wiring-errors` alone after the pooled suites, because that suite bounds each call with `timeout 30`.

`tests/lib/sandbox.sh` is the scaffolding of these suites and of harness-ci's wrapper suites: the fixture repository, the planted layout of both packages and the assertions. A control plants its mutant through `mutant`, which refuses a line that does not occur exactly once.

The change-scope suite installs and refreshes a real consumer with a real `kendex`. It skips those rows when no `kendex` is on PATH, and fails instead when `HARNESS_CI_REQUIRE_KENDEX` is set. CI builds the checkout's own `kendex-cli` on the Linux leg that runs these suites and sets `HARNESS_CI_REQUIRE_KENDEX` on every Linux leg; the macOS legs keep the skip. harness-ci's `change-class` suite judges its wrapper against this classifier over the same diffs.

`same-classification` holds the classifier to the answers recorded under `tests/fixtures/same-classification/`. Its header states how the answers were recorded. `SAME_CLASSIFICATION_RECORD=1` rewrites them from the classifier `SAME_CLASSIFICATION_CLASSIFIER` names; no suite runs it.

No shipped kendex exits 0 with failing rows, so `renders_match` never reaches `cause=verify-not-clean` under a real verifier. A mutant that removes that refusal survives the suites; the refusal guards a later kendex.

## Debug

Run the classifier against a local range and read its stderr:

```bash
skills/change-scope/scripts/change-scope --event pull_request --base origin/main --head HEAD --repo .
```

stderr carries the `changed-path:`, `base-rev:` and `head-rev:` lines `harness-only` read, a `harness-note:` line for its cause, the render proof's `render-verifier:`, `render-proof:`, `render-stale:`, `render-coverage:` and `render-position:` lines, any `settings-admission:` line, then `quick-proof:` and the `class:` line. A refused render prints the verify rows it weighed, so the log answers without a second `kendex verify` run.

## Invariants

- `harness-only` passes `--no-renames` to every diff, and no flag turns it off. With rename detection on, `git mv src/app.ts .agents/skills/x/app.ts` lists the render path alone and the product deletion goes unjudged. `tests/rename-into-render.test.sh` holds this.
- `VERIFY_DOCUMENT_VERSION` in `scripts/change-scope` is the one `kendex verify --json` document version the render proof reads. A kendex change that bumps the document's `version` bumps this pin in the same commit. `.github/workflows/skill-tests.yml` holds the built kendex's document to the pin before the render rows run.
- `BRANCH_GROWTH_CONTRACT` in `scripts/lib/branch-growth.sh` is for callers in other packages, installed at their own revisions; the library header states when it is bumped. `change-scope` ships with the library and checks no number. The outside caller is orch's `orch-runtime dev-return write` (`skills/orch/runtime/src/ops/artifact.rs`, `shared_measure`), which checks the number is at least 1 and refuses `baseline-read` otherwise. orch's tier calls `change-scope launch` (`ops/tier.rs`), which needs no number.
- The registry list in `scripts/lib/change-scope.sh` `change_class_path` holds one project-scope entry per structured settings surface the adapters under `crates/core/src/harness` name. An adapter that gains a hook, permission or MCP registry adds its path there. Copilot's entry is the glob `.github/hooks/*.json`, because `crates/core/src/engine/targets.rs` `copilot_hook` writes one file per hook. kendex owns keys in these files, never the file (`Owns::Keys` in `crates/core/src/engine/desired.rs`).
- A blank-separated glob list is split under `set -f`. With pathname expansion on, a glob that names a real directory becomes the files under the caller's working directory.
- The shipped scripts run on macOS system Bash 3.2. `tools/bash32-lint` scans them for Bash 4+ syntax.
