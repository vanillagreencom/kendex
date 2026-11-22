# change-scope development

Bash, `git` and `jq`. The render rows need a `kendex` on PATH, and the caller fallback needs `python3`.

## Test

```bash
bash skills/change-scope/tests/narrow-change.test.sh   # one suite; every suite is tests/*.test.sh
```

kendex's `.github/workflows/skill-tests.yml` runs the suites a change selects, in the merge group. It runs `wiring-errors` alone after the pooled suites, because that suite bounds each call with `timeout 30`.

The change-scope suite installs and refreshes a real consumer with the `kendex` on PATH, and skips those rows when none is there. `HARNESS_CI_REQUIRE_KENDEX` makes it fail instead. CI sets it on every Linux leg, with the checkout's own `kendex-cli` built; the macOS legs skip. harness-ci's `change-class` suite judges its wrapper against this classifier over the same diffs.

No shipped kendex exits 0 with failing rows. So `renders_match` never reaches `cause=verify-not-clean` under a real verifier, and a mutant that removes that refusal survives the suites. The refusal guards a later kendex.

## Debug

Run the classifier against a local range and read its stderr:

```bash
skills/change-scope/scripts/change-scope --event pull_request --base origin/main --head HEAD --repo .
```

A refused render prints the verify rows it weighed, so the log answers without a second `kendex verify` run.

## Invariants

- `VERIFY_DOCUMENT_VERSION` in `scripts/change-scope` is the one `kendex verify --json` document version the render proof reads. A kendex change that bumps the document's `version` bumps this pin in the same commit. `.github/workflows/skill-tests.yml` holds the built kendex's document to the pin before the render rows run.
- `BRANCH_GROWTH_CONTRACT` in `scripts/lib/branch-growth.sh` serves callers in other packages, installed at their own revisions. The comment above it states when to bump it. `change-scope` ships with the library and checks no number. The outside caller is orch's `orch-runtime dev-return write` (`skills/orch/runtime/src/ops/artifact.rs`, `shared_measure`). It refuses a number below 1. orch's tier calls `change-scope launch` (`skills/orch/runtime/src/ops/tier.rs`), which needs no number.
- The registry list in `scripts/lib/change-scope.sh` `change_class_path` holds one project-scope entry per structured settings surface the adapters under `crates/core/src/harness` name. An adapter that gains a hook, permission or MCP registry adds its path there. Copilot's entry is the glob `.github/hooks/*.json`, because `crates/core/src/engine/targets.rs` `copilot_hook` writes one file per hook.
- The scripts split a blank-separated glob list under `set -f`. With pathname expansion on, a glob that names a real directory becomes the files under the caller's working directory.
