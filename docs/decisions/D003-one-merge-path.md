# D003: One merge path through the merge queue, consumers pull renders, organization rulesets with zero bypass

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Approval**: the owner, directive 1790300329, 2026-09-25; amended by owner directive 1790322161 and owner notes 1790324783, 1790333777, 1790339825 and 1790348336, 2026-09-25; environment provisioning, its job list and the ruleset scope of step 3 settled by the overseer's answer A(i) to lane ask 1790337466, open to owner override

**Applies to**: every repository in the organization and every lane; [../architecture/merge-rail.md](../architecture/merge-rail.md), [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md), `skills/review-gate/templates/kendex-refresh.yml` (the refresh workflow template KEN-1779 adds)

## Context

A merge reached `main` by more than one route, and kendex renders reached consumers through a train the overseer drove from the control VM.

- Every merge of the last 14 pull requests before this decision was made by the owner's personal token through the overseer's admin verb (KEN-1646).
- The kendex merge-queue ruleset 20569265 listed Repository admin and two apps as bypass actors. The apps never used their bypass.
- Sandboxes already push with the installation token of the lanes app, `vanillagreen-fleet-lanes`, so a lane can arm auto-merge with that app.
- The queue is `ALLGREEN`, builds and merges up to five entries per group, squashes, and times a check out after 30 minutes.
- The consumer train runs on the control VM, driven by the overseer, and takes 5 to 35 minutes per train.
- PR 2860 lost about 40 minutes to a base-stale refusal: a pull request behind `main` had to restack before a direct merge.

## Decision

This is the target state, and each current route stays in place until the change that retires it lands. The admin merge and the `ORCH_MERGE_BYPASS` fast path stay until KEN-1777, the consumer train until KEN-1779, and each per-repository ruleset until the organization rulesets stand, the owner action KEN-1778 sequences.

On a hosted fleet the train stops at KEN-1773: the kendex overseer records the merge and notes each consumer's overseer, and consumers refresh from their own side until the KEN-1779 workflow; the train sentence above applies to a local fleet only.

1. **One merge path.** Every repository merges through its merge queue, and the lanes app arms auto-merge. No ruleset has a bypass actor, no admin route remains, and no owner credential sits on the control VM (KEN-1777). The queue serializes concurrent lanes and batches up to five pull requests per CI run, so a pull request behind `main` never restacks to merge. The queue run is cheap by class: the `merge_group` diff classifies like a pull request, a `render` or `trivial` group runs one job, and KEN-1750 removes the cargo lanes where no Rust path changed.
2. **Consumers pull.** kendex ships a refresh workflow template in its render (KEN-1779). The template reaches a consumer's `.github/workflows/` by adoption copy, as the review-gate writer template does per [adoption.md](../../skills/review-gate/references/adoption.md), because `kendex refresh` syncs no workflow YAML ([merge-rail.md](../architecture/merge-rail.md) § Boundaries). The lanes app is installed on all repositories at the organization, and a workflow in kendex `main` sends `repository_dispatch` with the lanes app token to every repository the app is installed on. Each consumer's copy runs on that dispatch, on a 30-minute schedule, and on `workflow_dispatch`. It installs a pinned kendex, runs `kendex refresh --scope project --yes --leave` and `kendex verify --scope project`, commits to the one rolling branch `kendex/refresh`, opens or updates one rolling pull request, and arms auto-merge on it. Its token comes from the `kendex` environment's secrets `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` through `actions/create-github-app-token`, scoped to the running repository and valid for one hour. The scoped app token commits, pushes, opens the rolling pull request and arms auto-merge; the built-in `GITHUB_TOKEN` is never used for any of these, because a pull request it opens starts no workflow and its required checks would never report. The pull request is `render` class: no review, one CI job, then the queue. No overseer and no control-VM toolchain take part. kendex never pushes to a consumer.
   - The `vanillagreen-fleet-lanes` app carries Contents read and write, Pull requests read and write, Workflows read and write, Administration read and Metadata read, set once on the app; the minted installation token requests the same set; no per-repository setting. Workflows write lets a commit change `.github/workflows/review-gate-writer.yml` or the refresh workflow itself, and Administration read is KEN-1781's ruleset read.
   - The two app secrets live in a GitHub Environment named `kendex` in each repository, whose deployment branch policy admits the default branch only. The refresh workflow's token-minting job and the kendex `main` dispatch job each declare `environment: kendex`, so a workflow on any other branch cannot read the secrets.
   - The owner-run provisioning command KEN-1799 ships creates that environment with its policy and sets its two secrets in every repository the lanes app is installed on. It is idempotent, so a new repository is provisioned by running the same command again and the owner does no per-repository work by hand. It runs from the owner's own machine under a credential the owner holds and picks, which is never stored on the control VM or a lane host. The adoption step in a consumer does not create the environment: it reads it, and fails naming KEN-1799's command when the environment is absent.
   - The lanes app never holds Administration write or Environments write. Either would let a lane create or rewrite the environment and undo its default-branch restriction.
   - A file the adoption step writes byte-for-byte from a template kendex ships is a render. KEN-1779 records each adoption-copied workflow file in `.kendex-generated.json` with the shipped template's hash, and `kendex verify` equality covers it; a file that differs from the shipped template is not a render and classifies `standard`.
   - A `render`-class pull request is outside the review gate by the class policy, objections included; KEN-1765 makes the class policy active by default. The refresh workflow answers every automatic-review finding on its rolling pull request in the review gate's own shape, naming the class and this rule: a thread gets one fixed reply and is resolved, so conversation resolution holds, and a review-body entry with no thread gets a line in a `Dispositions at <sha>` comment, per the `suppressed-findings` row of the [review-gate decision table](../../skills/review-gate/SKILL.md#decision-table). Each run also reads every merged `kendex/refresh` pull request that still has an unanswered automatic-review finding and answers each the same way, so a finding is handled whenever it arrives; the answer is the durable record. A finding that names a defect in a rendered file is filed upstream against kendex and never fixed on the rolling pull request.
3. **Organization rulesets.** Rulesets are organization rulesets that target all repositories. The default branch requires the merge queue, the required checks `Review gate` and one aggregate context `CI`, conversation resolution, and a Copilot review request, which holds no merge, with zero bypass actors. Per-repository rulesets are deleted once the organization rulesets stand. A new repository inherits everything on adoption, plus the app installation. Ruleset settings are set once at the organization level, never per repository. The GitHub apps act; no step swaps one token for another.
   - A pull request that repairs a broken gate engine cannot turn its own `Review gate` context green; it merges by the break-glass procedure [review-gate SKILL.md](../../skills/review-gate/SKILL.md#4-operations) § 4. Operations states. The steady state stays no standing bypass actor.

## Rationale

- A direct merge that bypasses the queue rebuilds every running queue group, so a mixed path costs more than either path alone.
- The queue removes the base-stale restack, because the queue, not the lane, puts the pull request on top of `main`.
- The lanes app already holds a push token in every sandbox. Arming auto-merge with it needs no new credential and removes the owner's token from the control VM.
- A consumer's own Actions runner does the refresh, so propagation costs the control VM nothing and needs no overseer.
- One organization ruleset gives every repository the same required contexts and no bypass, and a new repository gets them by joining.

## Alternatives Considered

| Alternative | Why rejected |
| --- | --- |
| The admin route: the overseer merges with the owner's personal token (KEN-1646) | It needs an owner credential on the control VM and a bypass actor on every ruleset, and each admin merge rebuilds the running queue groups. |
| Per-repository rulesets | Each repository drifts on its own, and every setting change is repeated per repository. |
| kendex pushes to consumers: the consumer train from the control VM | It loads the control VM for 5 to 35 minutes per train, needs the overseer, and needs a write credential for every consumer. |
| The app secrets as organization Actions secrets | An organization secret is readable by any workflow on any branch of every repository it reaches. One lane-pushed branch workflow could print the private key, which mints tokens for every repository the app is installed on. |
| A mixed path: direct merges beside the queue | A direct merge rebuilds every running queue group, which costs more than either path alone. |

## Consequences

- Each retired item and the issue that retires it:

| Retired | Where it lives, or lived until its issue landed | Issue |
| --- | --- | --- |
| The overseer's admin verb | `skills/orch/workflows/merge-pr-admin.md`, `pr-merge --admin-credential` | KEN-1777 |
| `ORCH_ADMIN_MERGE_GH_CONFIG_DIR` | `kendex.settings.toml`, `skills/github/scripts/commands/pr-merge.sh` | KEN-1777 |
| `ORCH_ADMIN_MERGE_CLASSES` | `kendex.settings.toml`, `skills/github/scripts/commands/pr-merge.sh` | KEN-1777 |
| `ORCH_MERGE_BYPASS` and its fast path | `kendex.settings.toml`, `skills/orch/workflows/merge-pr.md` | KEN-1777 |
| The user's admin override | `pr-merge --admin`, `merge_mode: admin` in `skills/orch/workflows/merge-pr.md`, the consumer admin-merge question in `skills/orch/workflows/submit-pr.md` | KEN-1777 |
| The user's force override, per owner note 1790348336 | `pr-merge --force` in `skills/github/scripts/commands/pr-merge.sh` | KEN-1777 |
| The merge-ready ask | the overseer's launch brief, `tmp/launch-brief-template.txt` on the control host and not a repository file, whose sentence is deleted the day KEN-1777 merges; `skills/orch/workflows/merge-pr-admin.md`; `skills/orch/references/oversee-events.md` § Admin merges | KEN-1777 |
| The `vanillagreen-merge-rail` app | the organization's app installations and the ruleset bypass list; nothing in this repository references it | KEN-1777 |
| The owner credential on the control VM | the gh config directory the retired `ORCH_ADMIN_MERGE_GH_CONFIG_DIR` named, `/home/dev/.config/gh-admin`, holding an organization-admin OAuth token; the owner deletes the directory and revokes the token in GitHub once KEN-1777 merges | KEN-1777, an owner action |
| `consumer-train.md` and its manual steps | `skills/orch/workflows/consumer-train.md` | KEN-1779 |
| `ORCH_CONSUMER_REPOS` | `skills/orch/workflows/consumer-train.md`, `skills/orch/kendex.settings.toml.example`, its row in `skills/orch/README.md` § Settings | KEN-1779 |
| The train step under `merged` | `skills/orch/references/oversee-events.md` § Event kinds | KEN-1779 |
| Propagation as the only write lane into consumers | `.agents/skills/kendex-issues/SKILL.md` § Propagate and its Consumer boundary line | KEN-1779 |
| The other train mentions | `skills/orch/SKILL.md`, `skills/orch/workflows/micro.md`, the `consumer_train` field in `skills/orch/schemas/workflow-state.md` | KEN-1779 |
| The create-time sandbox refresh | `kendex update-pi` and `kendex refresh` in `skills/orch/scripts/lane-host-ssh` create, `skills/orch/schemas/lane-host.md` | KEN-1780 |
| Each per-repository ruleset, kendex's merge-queue ruleset 20569265 among them, with its bypass actors | each repository's ruleset settings in GitHub; nothing in this repository | KEN-1778, as the owner action after it lands in every repository |

- KEN-1777 updates the review-gate contract that names the ruleset bypass actor as the gate-repair merge path: the gate-repair and settings-change lines in [../../skills/review-gate/SKILL.md](../../skills/review-gate/SKILL.md) § 4. Operations, [../../skills/review-gate/references/settings.md](../../skills/review-gate/references/settings.md) § Security posture, the Bypass actor line in [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md) § Repo-side wiring, and the bypass-actor wiring in SKILL.md § 2. Adopt and adoption.md § What an adoption PR contains, item 6.
- KEN-1777 rewrites [../architecture/merge-rail.md](../architecture/merge-rail.md) § Ownership, § Boundaries and § Decisions to this decision's end state.
- Each repository reports one aggregate required context `CI` beside `Review gate`, and `merge_group` classifies through the same class job set (KEN-1778).
- A lane's worktree comes from a current `main` (KEN-1780).
- A review-gate validation reports, read-only, whether a repository's rulesets, required contexts and app installation match this decision. Per repository it also reads that the `kendex` environment exists, carries the default-branch-only deployment policy and holds the secrets `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` (names only), and that no repository or organization secret of those names exists outside it. It also reads that the lanes app holds neither Administration write nor Environments write. `kendex check` relays its verdict (KEN-1781).
- `.github/workflows/publish-homebrew.yml` `publish` also mints a token from the two secrets, today read as ordinary Actions secrets that [../../packaging/README.md](../../packaging/README.md) § Publishing tells the reader to add. It moves under `environment: kendex` with a deployment policy that admits the refs it runs from, and that README stops telling the reader to add ordinary secrets. The move lands as its own item through the proposal route, not with KEN-1777; until it does, KEN-1781 flags those copies of the two secrets outside the environment.
- The kendex app and CLI open no pull request in a consumer; [../architecture/overview.md](../architecture/overview.md) § Decisions states it.
- Owner GitHub steps: install the `vanillagreen-fleet-lanes` app on all repositories with the permission set step 2 records; stand the organization rulesets step 3 records (KEN-1778); run KEN-1799's provisioning command from the owner's own machine, once and again for each new repository.

**Revisit When**: GitHub organization rulesets or the merge queue are unavailable to a repository kendex must serve; a consumer cannot run GitHub Actions or obtain its repository-scoped token; or a queue run for a `render` or `trivial` group costs more time than the direct merge it replaced.

**Verification**: KEN-1781's validation, once it lands, runs under a lanes app installation token once the owner sets Administration read on the app, as step 2 records. Until then a token without that permission reads the bypass-actor list as empty, and the owner reads the organization ruleset settings in GitHub: zero bypass actors, the merge queue and the two required contexts.

**References**: KEN-1776, KEN-1646, KEN-1672, KEN-1750, KEN-1765, KEN-1773, KEN-1777, KEN-1778, KEN-1779, KEN-1780, KEN-1781, KEN-1799; superseded: KEN-1601, KEN-1602
