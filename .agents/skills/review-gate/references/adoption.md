# Adopting the review-gate engine

How a repo wires the shared engine: the writer workflow, the validate step, rulesets, per-repo settings, and what an adoption PR deletes.

## The precondition — check before anything else

The gate never polices CI. A repo must satisfy ONE of these:

1. **A merge queue** whose required contexts include the repo's `CI` aggregate (recommended).
2. **No held-back jobs** — every required check runs on every push.

Held-back jobs report `skipped`, and GitHub counts skipped as satisfied.

## What an adoption PR contains

1. **Vendor the skill** (`kendex refresh` places `.agents/skills/review-gate/scripts/` and these references). The consumer's drift check asserts the vendored copy matches the catalog byte-for-byte.
2. **Copy `.agents/skills/review-gate/templates/review-gate-writer.yml`** into `.github/workflows/`, VERBATIM. It carries no per-repo values. `kendex refresh` updates the vendored template but never writes `.github/workflows/`; a template update reaches the copy through `.agents/skills/review-gate/scripts/validate-workflow.sh --adopt`, run after `kendex refresh` (§ Updating an already-adopted copy). The one workflow is the ONLY writer of the gate status; every leg that runs the engine runs the DEFAULT-branch one (PR-attached legs relay). Renaming the copy needs no further change. Keep every line of the relay's `env:` block (`GH_REPO`, `DISPATCH_REF`, `WORKFLOW_REF`, `EVENT_NAME`, `CHECK_NAME`).
3. **Add the validate job** to the repo's CI (below).
4. **Set the repo's `REVIEW_GATE_*` keys** in `kendex.settings.toml` (decision axes below; full key table in [settings.md](settings.md)).
5. **Delete everything the writer supersedes in the same PR** — gate jobs that read the predicate to condition CI, rerun/refire/sweep workflows and scripts, local predicate copies, duplicated gate steps.
6. **Repo-side wiring** (below): rulesets and merge queue, with no standing bypass actor.
7. **Reviewer instruction for the vendored tree** — wire the remedy-locus rule from [vendored-paths.md](vendored-paths.md), never a reviewer path exclusion.

## Recommended CI shape — the fast/full split

Recommended split: cheap fast checks (lint, typecheck, unit) run on every push unconditionally; heavy suite jobs carry `if: github.event_name == 'merge_group'` and run only in the queue. Running everything on every push is also allowed. Jobs must NOT read the predicate to decide whether to run.

## The validate job

```yaml
  review-gate-validate:
    # DELIBERATELY UNGATED: no `needs`, no approval condition, no path
    # filter.
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - name: Validate this repo's review-gate installation
        run: .agents/skills/review-gate/scripts/validate.sh
```

Each check emits an `ok` or `FAIL` record with `check=CODE value=VALUE`. Indented lines give the explanation and repair. Exit 0 means clean, 1 means findings, and 2 means the check could not run. It answers repo-own questions only — the engine is installed and runnable here, the committed `REVIEW_GATE_*` values are legal, the carry-forward exclusions still match tracked paths, and the adopted workflow still meets this template's contract. It re-runs no engine test suite: the selftest and the wrapper suites are the ENGINE's proofs and run in the kendex repo on every change to it.

Value rules come from the engine, not from a copy of it: the settings half calls the engine's own value judges, which `validate.sh --help` names, and none of them reads evidence or needs a PR.

## Repo-side wiring

The organization rulesets carry this shape for every repository. Until they stand, the repository's own ruleset carries it. `scripts/validate-standard.sh` reports each part of it.

`validate-standard.sh` and `provision-environment.sh` read the organization's own values from settings, since the package ships none. Before either runs, declare in the `[env]` table of the repository's `kendex.settings.toml` ([settings.md](settings.md)):

1. `REVIEW_GATE_STANDARD_APP`: the slug of the GitHub App the organization installs on every repository.
2. `REVIEW_GATE_STANDARD_ENVIRONMENT`: the environment that holds that app's secrets.
3. `REVIEW_GATE_STANDARD_SECRETS`: those secrets' names, `;`-separated. Never their values. A name is uppercase letters, digits and underscores, and does not start with a digit. GitHub stores every secret name uppercase.

Each script exits 2 with one `standard-setting-missing` record naming every key it reads that is unset or empty, or with one `standard-secret-invalid` record naming every secret name outside that grammar. Refresh adoption reads none of these keys (§ Automatic consumer refresh).

A repository reaches this shape in one order. The workflow change that reports `CI` on `pull_request` and `merge_group`, both under `on:`, and the ruleset change to exactly `CI` and `Review gate` apply back to back. Where the workflow change renames an existing aggregate, the ruleset changes first and the rename merges through the queue at once. After the first merge through the queue, `scripts/validate-standard.sh` runs: its `standard-ci-context` ok confirms the workflow change on both legs, and its `standard-required-contexts` and `standard-merge-queue` oks confirm the ruleset change.

- **Required contexts**: exactly two, `CI` and `Review gate`, the `ci_context` and `gate_context` of the skill's `standard.json`. `Review gate` is the repo's `REVIEW_GATE_CONTEXT` value. `CI` is the aggregate [harness-ci wiring.md § The CI context](../../harness-ci/references/wiring.md#the-ci-context) describes.
- **Merge queue**: required on the default branch. The writer's `merge_group` leg posts the gate context on queue shas unconditionally.
- **Thread resolution**: a pull-request rule requires every review thread resolved.
- **Copilot review**: a rule requests a Copilot review, which holds no merge.
- **No bypass actor**: no ruleset carries one, a Repository-admin actor included, so every merge goes through the merge queue. A gate-repair PR takes the break-glass procedure in [../SKILL.md](../SKILL.md#4-operations); a settings-change PR takes normal review.
- **No classic branch protection** beside the rulesets.
- **Required checks must NOT include the writer's own job names.** Require the commit STATUS context only.
- **App-secret environment**: the organization owner runs `.agents/skills/review-gate/scripts/provision-environment.sh --org ORG` from their own machine, in a checkout that declares the three settings above. It creates the environment `REVIEW_GATE_STANDARD_ENVIRONMENT` names, with a default-branch-only deployment policy and the secrets `REVIEW_GATE_STANDARD_SECRETS` names, in every repository of the organization that is not archived; run it again for a new repository. An adoption never creates the environment.

## Updating an already-adopted copy

After `kendex refresh` brings a new template, run `.agents/skills/review-gate/scripts/validate-workflow.sh --adopt` from the repository root and commit its write with the refresh. It compares the copy against every version of the template this repository's history holds:

- A copy equal to the current template is left as it is: `ok check=workflow-equality`.
- A copy equal to an earlier shipped version is re-installed from the current template, keeping its script path and its `check_run` opt-in: `ok check=workflow-readopted`. The re-install writes the template's bytes, so a comment-only edit to the copy is replaced.
- A copy whose code lines equal no shipped version is one a person edited. It is left untouched and named on one `FAIL check=workflow-edited` line, with the first divergent line under it. Re-copy the template by hand.

Run it after every `kendex refresh` so template changes land with the refresh. The consumer refresh workflow calls it through `scripts/adopt-refresh.sh`.

### Automatic consumer refresh

The shipped `templates/kendex-refresh.yml` checks for updates every 30 minutes. A manual run uses the same path. Each run updates `kendex/refresh`, keeps one open pull request, and enables auto-merge with the repository's app token. Required CI checks and the merge queue still control merging. An unchanged result opens no pull request.

Provision the `kendex` environment before adoption. It must contain `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` and allow deployments from the default branch only. The organization owner uses `scripts/provision-environment.sh --org ORG` from their own machine. `scripts/adopt-refresh.sh` reads the existing environment through `validate-standard.sh --environment-only`. It checks the environment and secret names the refresh template it installs reads, whatever the consumer's `REVIEW_GATE_STANDARD_*` settings say, so refresh adoption needs none of those keys. A missing environment, secret or branch policy stops adoption with the failed check and provisioning remedy.

After installing the skill and copying the writer verbatim, stage that writer so the validator can find it. Run from the consumer root:

```bash
git add .github/workflows/review-gate-writer.yml
.agents/skills/review-gate/scripts/adopt-refresh.sh
kendex verify --scope project
git add .github/workflows/kendex-refresh.yml .kendex-generated.json
```

A repository that posts no gate status adopts the refresh workflow with no writer. It sets `REVIEW_GATE_WRITER = "optional"` and `REVIEW_GATE_MODE = "off"` in its committed `kendex.settings.toml`, where both keys are read from, copies no writer, and runs `adopt-refresh.sh` and `kendex verify` as above. Adoption then records only the refresh copy and retires any earlier writer record. Either setting alone still refuses a missing writer, a workflow that names `review-writer.sh` outside a comment still fails, and a writer that is present is still checked and updated. The class policy still applies: a change it resolves to `bot` still needs review evidence, which no status reports without a writer. `REVIEW_GATE_MODE = "off"` also skips orch's review wait, except where the class policy resolves a change to `bot` and `PR_REVIEW_GATE` then decides ([orch gates](../../orch/references/gates.md)).

Commit the workflow copies and inventory with the installed skill. Adoption records each byte-identical copy's template path and SHA-256 hash. `kendex refresh` updates the template and its expected hash. Adoption then updates an unedited copy. Verification and the shared change classifier compare the copy with the declared package template. Verification rejects a registered copy that differs from its template. A writer with local path or trigger changes is not an exact copy and is not registered as a render by this command.

Schedule and manual refresh work in a consumer with the app installation and environment above. Instant refresh also needs organization dispatch wiring. The catalog's `.github/workflows/kendex-dispatch.yml` signals every non-archived consumer repository visible to its app installation after a push to `main`. Adoption and dispatch exclude `vanillagreencom/kendex`, whose build-bound lock workflow owns its refresh under D007. It attempts all destinations and fails the run if any dispatch fails.

Only the default-branch workflow can use the private key. It checks out the default branch before minting a repository-scoped app token. It rebuilds the rolling branch from that checkout and proves the full diff is a render before pushing. It preserves the default-branch review scripts in a detached worktree before refreshing. Those scripts prove that each rolling pull request has class `render` before they file, reply to or resolve an automatic review thread. Findings on other classes remain unchanged.

The last two steps request an Issues-write token scoped only to `vanillagreencom/kendex`, then use it to file findings and resolve their threads. Each automatic review thread on a render-proven pull request has one of two outcomes:

- `kendex report` routes the finding's one package to `vanillagreencom/kendex` with a package label: the workflow files the finding there for upstream confirmation, replies with the issue, and resolves the thread. GitHub-to-Linear sync sends the reports to KEN Triage. The report carries the review evidence, rendered path, consumer run and that package label. Its stable title fingerprint finds an existing open issue on later runs.
- Every other finding is not filed, and the error line gives the reason: no single package claims the path (the lock, the inventory, a Copilot `.github/agents/*.agent.md` render), `kendex report` does not route the package to `vanillagreencom/kendex`, or the token or Issues access is missing. Review text about content kendex has not claimed is never published.

A not-filed thread stays open, the thread-resolution rule holds the merge, and the run fails with an error naming the thread. Report the finding where it belongs and resolve the thread by hand: a resolved not-filed thread no longer fails the run. A reporter failure holds only its own pull request and also fails the run. If the token lacks Issues access, the Actions summary supplies filing links for routed findings only. A later run with the token files the finding and resolves the thread. A pull request the classifier cannot measure keeps its findings unanswered, and the run adds a warning with the cause.

### The relay/converge split

The template delta that split the writer into a relay and a converge leg:

- A `request-converge` job (the relay) runs every PR-attached leg; the `write` job's `if:` is narrowed to `workflow_dispatch`/`schedule`.
- **Permissions**: the relay holds `actions: write` and nothing else — no `contents`, no `statuses`, no `issues`. `actions: write` authorizes dispatching **any** workflow in the repo plus cancelling, re-running and deleting runs, logs and artifacts. The relay checks nothing out and executes no PR-controlled code — never add a checkout to this job. The `write` job holds no `actions` scope.
- **The relay files no rolling escalation issue.** That stays on the `write` job. A sustained dispatch outage is detected through **gate staleness**: `pr-watch.sh --heal` dispatches one writer run per invocation on `gate-stale`. Each relay run's log carries a `::warning::`. For a louder signal, add it to staleness monitoring, not to the relay's scope.
- **`workflow_dispatch` must stay in `on:`** — it is the dispatch target. Dropping it strips every event-fast path down to the cron floor.
- The opt-in `check_run` trigger ships commented out. To enable it, uncomment the two trigger lines and set the repository variable `REVIEW_GATE_CHECK_RUN_NAME` to the reviewer's check name — the relay's `if:` already reads it, so no expression is hand-edited. An unset variable matches no check name, so the trigger without the variable relays nothing. The step separately refuses to dispatch on a `check_run` naming one of its own three jobs; that refusal is a literal list of the three job `name:` values — if you rename a job in your copy, rename it in the list too.
- **Check the ruleset first** if it ever named a writer JOB (rather than the gate status context): a required `Evaluate and write the review gate` would block every PR. Require the status context only.

- **The relay never exits non-zero.** Invariant when editing the copy. Every fault warns and exits 0, and every wait is bounded (`timeout` per dispatch attempt, a floored and capped backoff, and a `timeout-minutes` that outlasts the worst case). Do not restore fail-loud here.

  It makes two dispatch attempts, classifying the server's answer:

  | Answer | Wait | Recognized by |
  |---|---|---|
  | Rate limit | The named window, floored at 60s, plus bounded jitter; a window beyond 120s skips the retry | `retry-after`; `x-ratelimit-reset` *only when `x-ratelimit-remaining` is 0*; a header-less secondary limit, from its body or an HTTP 429 |
  | Transient | 5s | Anything else retryable |
  | Permanent | Not retried | 400; 404 (renamed workflow file); 405; 422 (bad ref); 401 (revoked token); 403 carrying no rate-limit evidence (`Resource not accessible by integration`) |

  Never treat `x-ratelimit-reset` as a wait instruction on its own.

Cost per repo: one extra Actions run per PR-attached event, up to about 4.2 minutes of runner hold in the worst modeled failure (inside the job's 5-minute budget), one or two content-creating API requests per run against the secondary-limit budget, and one extra run lifecycle of event-fast latency. The relay is group-less and coalesces nothing. Repos on a constrained or self-hosted runner pool size that before adopting.

Verify after adopting — run both:

1. **Something was actually dispatched.** After a push to an open PR, `gh run list --workflow "Review gate writer" --event workflow_dispatch --limit 5` must show a run created just after it. If nothing appears, the relay's own run log carries a `::warning::` naming the cause (a missing `actions: write` is the usual cause).
2. **No cancelled check pins the PR.** Push twice in quick succession, then confirm `gh pr checks` shows no cancelled writer entry and `gh pr view --json mergeStateStatus` is not `UNSTABLE` on that account.

## Keys a repo decides

Concrete per-consumer values are tracked on the org adoption issue, not here. Everything else has a working default. Full key table: [settings.md](settings.md).

| Key | Decide |
|---|---|
| `REVIEW_GATE_CONTEXT` | The protected commit-status name. Renaming it means updating the ruleset in the same PR. |
| `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | The reviewer contexts whose clean pass counts. Any context to trust needs an explicit entry. |
| `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` | Default closes the rate-limited-pass gap everywhere; empty is an explicit opt-out. |
| `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` | Empty = any non-author. List logins to restrict — do that wherever outside collaborators can review. |
| `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | `any` counts COMMENTED reviews (for bots that never APPROVE); `approved` requires an APPROVED verdict. |
| `REVIEW_GATE_COMMENT_REVIEWERS` | Only for a comment-form reviewer: `login:binding-prefix`. |
| `REVIEW_GATE_SHA_PREFIX_FLOOR` | Shortest SHA prefix accepted by both binding readers: comment-form reviewer evidence, and the author's suppressed-finding disposition comment. |
| `REVIEW_GATE_OVERRIDE_CONTEXT` | The operator override status context. |
| `REVIEW_GATE_STATUS_PUBLISHER_REJECT` | Set `github-actions[bot]` wherever PR workflows hold `statuses: write`. Requires the override to be posted by a non-Actions identity (operator PAT). Empty disables. |
| `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | Default closes the errored-auto-review gap; override where a repo's reviewer words its attestation differently; empty is an explicit opt-out. |
| `REVIEW_GATE_THREADS` | `enforce`, unless a server-side zero-bypass thread ruleset is the enforcement point. |
| `REVIEW_GATE_CARRY_FORWARD` | Off by default. Turn on `docs`/`comments` where re-review of review-inert deltas is unwanted; `vendored` where `kendex refresh` pushes should carry, with the render trees listed in `REVIEW_GATE_VENDORED_PATHS`. |
| `REVIEW_GATE_VENDORED_PATHS` | The render trees `vendored` trusts as kendex output, e.g. `.agents/*;.claude/skills/*`. A hand-edit under them rides; keep hook scripts and instruction markdown in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which wins. |
| `REVIEW_GATE_CLASS_POLICY` | Leave it unassigned. The built-in default is the active value in the [README class table](../README.md#class-policy): it exempts `render`, `trivial` and `micro`, requires one bot round for `small`, and keeps the current policy for `standard`. An adoption never writes an empty value. |
| `REVIEW_GATE_CLASS_POLICY_DECISION` | Leave it empty. A repository that assigns other rows, or `REVIEW_GATE_CLASS_POLICY = ""` to turn the policy off, names here, by its path from the repository root, the tracked decision record behind that choice. |
| `REVIEW_GATE_DOCS_ONLY` | Leave it unassigned under the default class policy. The lane applies only after a recorded opt-out from the class policy. After an opt-out, `bot` keeps review evidence mandatory, and `none` lets the shared CI docs classifier replace missing bot evidence while objections, suppressed findings, unresolved threads, and excluded paths still block. |
| `REVIEW_GATE_RENDER_PATHS` | Leave it unassigned under the default class policy. The lane applies only after a recorded opt-out from the class policy. After an opt-out, it names render trees that may merge on CI alone. Empty disables the lane. |
| `REVIEW_GATE_MODE` | `enforce`. `off` disables an inactive or `current` class policy and attests rather than evaluates. A `bot` class still requires review. |
| `REVIEW_GATE_WRITER` | `required`. `optional`, with `REVIEW_GATE_MODE = "off"`, only in a repository that runs the automatic refresh and posts no gate status. |
| `REVIEW_GATE_STANDARD_APP`, `REVIEW_GATE_STANDARD_ENVIRONMENT`, `REVIEW_GATE_STANDARD_SECRETS` | The organization's app, app-secret environment and secret names (§ Repo-side wiring). No default. `validate-standard.sh` and `provision-environment.sh` refuse on each unset key. `validate-standard.sh --environment-only` reads the environment and secret keys only. Refresh adoption reads none of them. |

## Repair by verdict line

| Verdict line | What to do |
|---|---|
| `settings-unknown` | Fix the spelling against [settings.md](settings.md). The written value is being ignored. |
| `settings-values` | Read the indented engine diagnostic. Its first record identifies the setting error; the following lines explain the accepted values. A nested `predicate-pattern` record means the path pattern uses an unsupported anchor or metacharacter. |
| `carry-unmatched` | Fix the glob, or declare it in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` when it guards paths that do not exist yet. |
| `carry-declaration-matched` or `carry-declaration-missing` | Reconcile the ledger — every declaration names an active exclusion that still matches nothing. |
| `workflow-count` | Adopt (§ What an adoption PR contains), or `git add` the workflow: Actions runs only what is committed. A repository that posts no gate status sets `REVIEW_GATE_WRITER = "optional"` and `REVIEW_GATE_MODE = "off"` instead. |
| `workflow-absent-mode` | The writer is optional but the gate is enforced. Set `REVIEW_GATE_MODE = "off"`, or adopt the writer. |
| `settings-writer` or `settings-writer-source` | Set `REVIEW_GATE_WRITER` to `required` or `optional` in the committed `kendex.settings.toml`, never in `.kendex/settings.toml`. |
| `settings-lock-kendex` | Set `REVIEW_GATE_LOCK_KENDEX` to empty or `main`; the indented `policy-lock-kendex` record names the value `review-policy` refused. |
| `workflow-equality` | Run `validate-workflow.sh --adopt` (§ Updating an already-adopted copy) and commit its write. The `note check=workflow-template` line under the verdict names the template blob the copy was compared against. |
| `workflow-edited` | A person edited the copy. Re-copy `templates/review-gate-writer.yml` over it; the line named under the verdict says where it diverges. Keep only the `check_run` opt-in's two trigger lines if that opt-in is on. |
| `class-policy-undecided` | Delete the `REVIEW_GATE_CLASS_POLICY` assignment so the default applies. A departure from the default needs a decision record named in `REVIEW_GATE_CLASS_POLICY_DECISION`. |
| `class-policy-decision-untracked` | Commit the decision record, or correct the path in `REVIEW_GATE_CLASS_POLICY_DECISION`. |
| `class-policy-unresolved` | Read the indented `review-policy` diagnostic. |
| `settings-values` with `policy-classifier` | The `harness-ci` skill is not installed beside review-gate: install it with `kendex add`. |
| `carry-load` | Read the nested `settings-unreadable` or `settings-syntax` diagnostic. It names the key and the shape the loader rejected. Fix the assignment; an unreadable value is never an empty one. |
| `runtime-mode` or `runtime-syntax` | Re-run `kendex refresh` and commit the result. |

## Migrating a v1 consumer (rerun/sweep-era wiring)

A repo on the pre-writer machinery deletes, in one PR: its `approval-rerun.yml` / `approval-sweep.yml` (or equivalents), any CI gate job that evaluates the predicate to skip heavy jobs, any local refire / convergence scripts, and the `REVIEW_GATE_TRUST_PR_WORKFLOWS` / `REVIEW_GATE_MAX_RERUN_ATTEMPTS` keys (both retired). It adds the writer workflow, applies the fast/full split to its CI, and updates its own docs from the legacy override key to `REVIEW_GATE_OVERRIDE_CONTEXT`.

## Watching PRs as an agent (pr-watch)

`.agents/skills/review-gate/scripts/pr-watch.sh` is a needs-attention reducer for sessions shepherding one or many PRs. Never watch gate-state *transitions*.

Wrap it in whatever wake-up mechanism the harness has — the loop body is always the same:

```bash
# cron / polling loop / harness monitor — silence means nothing needs you.
# Run it BARE, once; the exit code is the predicate. Never invoke it a
# second time to build a notification.
export GH_REPO=your-org/your-repo
.agents/skills/review-gate/scripts/pr-watch.sh --heal
```

(The `export` is its own line, not a command prefix.)

Exit 0 = silence (healthy); exit 1 = attention lines on stdout (threads to triage — queued PRs annotated with the dequeue-first warning — objections, a stale gate, a disarmed mergeable PR, reviewer silence past the quiet period, or `head-moved` when a push landed mid-reduction — re-run); exit 2 = a PR could not be read (fail loud, never skipped). `--heal` bounds itself to one writer dispatch per invocation and reports it as an informational `heal-dispatched` line. The orch skill's waiters are the single-PR *foreground* waits; pr-watch is the multi-PR *background* reducer over OPEN PRs only.

`--no-evaluate` skips the predicate but still reads threads, queue state, and gate status, so `threads-open`, `disarmed`, and the threads-driven `gate-stale` form still fire; verdict-driven forms need the predicate. `--awaiting-after SECS` replaces the `PR_REVIEW_WAIT_SECS` threshold.

## Verification

- `.agents/skills/review-gate/scripts/validate.sh` exits 0 from the repo root.
- The consumer's vendored-copy drift check passes.
- The first PURE re-vendor PR after adoption carries a trusted non-author review object at head, and on the vendored tree no unresolved thread from a summary-capable reviewer, except one raising a carve-out regression (which correctly blocks — read before resolving anything). A location-bound reviewer's threads are recorded, not graded ([vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR).
