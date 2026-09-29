# CI stage targets against measured values

A kendex pull request should pass its own checks in under 10 minutes, spend under 15 minutes in the merge queue with 95 percent of merge-group runs passing (under 5 percent failed), and merge within 20 minutes for a micro change, 30 minutes for a small one and 90 minutes for a standard one. Measured over 94 pull requests merged from 2026-09-26 to 2026-09-28, pull request checks, the merge queue and open to merge each miss their target at the median of the standard class, the one class large enough to judge a median (§ Targets against measured values); the micro and small medians miss as well. The queue's CI run alone takes a median of 24 to 29 minutes, and 34 percent of queue runs failed (51 of 150). Micro changes, the smallest, took the longest (median 151 minutes against a 20-minute target), all of it queue wait. Standard changes miss their 90-minute target at the median (115 minutes) and at the tail, and their main blocker is the review-and-fix loop before the final push. Of the 51 failed queue runs, 24 were real macOS-only defects the pull request run never ran (KEN-2031), 15 were a document byte ceiling ejecting a group for a budget (KEN-2039), and 12 were flaky tests (KEN-2043 to KEN-2047, KEN-2008). The admin merge now takes a green pull request past the queue ([park-and-resume.md § 3 Admin merge route](park-and-resume.md#admin-merge-route)), and the doc checks table below settles which checks may eject a group.

Design note, 2026-09-28. Built from the overseer's stage-targets and CI-data drafts, re-measured under owner decision 1790634126 item 7: the class comes from the cycle record only, and every group-run count is one recount over one window.

## Sources and windows

- Pull request set: the 94 kendex pull requests that carry an oversee-cycle row in the fleet's cycle record (`cycle-rows-20260928.json`, attached to KEN-2050: 95 `cycle` rows, one per pull request), merged 2026-09-26 18:41Z to 2026-09-28 21:35Z. The class is the row's `class=` value and nothing else: micro 3, small 5, standard 86. One row, KEN-1907 pull request 422, is a vanillagreencom/vgs pull request and is left out.
- Pull request stamps and CI spans: `.agents/skills/github/scripts/github.sh pr-timeline N` for each of the 94.
- Merge-group runs: `gh run list -R vanillagreencom/kendex --workflow 'Skill Tests' --event merge_group --created 2026-09-27T17:00:00Z..2026-09-28T18:00:00Z --limit 1000`, recounted 2026-09-28: 150 runs, 88 success, 51 failure, 11 cancelled, created 2026-09-27 17:28Z to 2026-09-28 17:44Z. This recount replaces two figures that disagreed with it: 41 failed of 98 (KEN-2031's first figure, also cited by KEN-2037) and 288 groups (the stage-targets draft, which grouped both workflows by queue branch over 2026-09-25 18:00Z to 2026-09-28 18:07Z). The Review gate writer's merge-group leg ran 150 times in the same window, all green, so a failed group is a failed Skill Tests run.
- Failed-run classification: the job logs of the 51 failed runs, read by the overseer on 2026-09-28; the 51 run ids equal the recount's 51 failures.
- Job-level figures (shard walls, stand-down counts): the jobs of the same window's runs, read by the overseer on 2026-09-28.
- Fleet figures: read by the overseer on 2026-09-28; this repository's token cannot read the fleet repository.
- Next measurement: 2026-10-01, over the pull requests merged 2026-09-29 to 2026-10-01.

## Targets against measured values

Median and p90 use the nearest-rank method; with n=3 the p90 is the largest value. Micro (n=3) and small (n=5) are too few pull requests to judge a median; only the standard column (n=86) supports one. The four admin merges (small: 3089; standard: 3072, 3074, 3081) ran no merge group and are left out of the two merge-group rows.

| Measure | Target | micro (n=3) | small (n=5) | standard (n=86) |
|---|---|---|---|---|
| PR checks wall, final head (min) | under 10 | median 14, p90 14; 1 of 3 under | median 13, p90 22; 0 of 5 under | median 13, p90 28; 7 of 86 under |
| Merge-group CI run (min) | under 15 | median 29, p90 43; 1 of 3 under | median 25, p90 30; 0 of 4 under | median 24, p90 29; 2 of 83 under |
| Merge queue, queued to merged (min) | under 15 | median 133, p90 137; 0 of 3 under | median 26, p90 33; 0 of 4 under | median 25, p90 48; 1 of 83 under |
| Merge-group runs failed | under 5 percent | 34 percent (51 of 150), one figure for all classes | same | same |
| Open to merge (min) | micro under 20, small under 30, standard under 90 | median 151, p90 161; 0 of 3 under | median 47, p90 873; 1 of 5 under | median 115, p90 661; 37 of 86 under |
| Main blocker (PRs whose longest gap ends there) | none | merge queue 3 | review-and-fix loop 2, merge queue 2, wait for queue entry 1 | review-and-fix loop 43, merge queue 33, wait for queue entry 6, final-head checks 4 |
| Review rounds per PR | micro 1, small 1, standard 2 | first measured 2026-10-01 | first measured 2026-10-01 | first measured 2026-10-01 |
| Review round, push to review (min) | under 10 | first measured 2026-10-01 | first measured 2026-10-01 | first measured 2026-10-01 |
| Fix round, review to next push (min) | none named | first measured 2026-10-01 | first measured 2026-10-01 | first measured 2026-10-01 |

The three review-stage rows come from owner decision 1790637688, which makes review rounds their own CI stage; the round targets are owner note 1790619146 item C. The 94 pull requests above were measured before `pr-timeline` read review rounds, so the next measurement run fills these rows.

The 15-minute merge-group target is unreachable while the merge-group Skill Tests run takes 27.9 minutes at the median (p90 37.1) over the 150 runs in the window. Its slowest leg, the guards-tools macOS shard, runs 25.3 minutes at the median and 29.6 at most against its 30-minute timeout. KEN-2031 runs every merge-group job the touched paths select on the pull request, and owner decision 1790634126 item 2 adds splitting that shard so PR checks approach their 10-minute target.

## Main blocker per class

- micro: the merge queue, on all 3. PRs 3067, 3071 and 3078 queued for 137, 133 and 56 minutes, and each wait spans failed groups listed in § Failed merge-group runs.
- small: no single blocker; the review-and-fix loop and the merge queue each hold 2 of 5, and the admin-merged 3089 waited longest for queue entry.
- standard: the review-and-fix loop before the final push, on 43 of 86; the merge queue on 33.

## Merge-group runs

Window and count as stated in § Sources and windows.

| Repo | Workflow | Runs | Failed | Fail rate | Cancelled | Wall median | Wall p90 |
|---|---|---|---|---|---|---|---|
| kendex | Skill Tests | 150 | 51 | 34.0% | 11 | 27.9 min | 37.1 min |
| kendex | Review gate writer | 150 | 0 | 0% | 0 | 0.2 min | 0.3 min |
| fleet | CI | 43 | 1 | 2.3% | 0 | 5.3 min | 5.7 min |

Wall time is `updatedAt` minus `createdAt`. The Review gate writer's merge-group leg is a no-op that posts green.

## Pull request runs

Same window, `--event pull_request`.

| Repo | Workflow | Runs | Failed | Cancelled | Wall median | Wall p90 |
|---|---|---|---|---|---|---|
| kendex | Skill Tests | 160 | 21 | 13 | 13.2 min | 22.3 min |
| kendex | own-catalog | 160 | 0 | 0 | 2.0 min | 2.2 min |
| fleet | CI | 71 | 7 | 0 | 5.4 min | 6.0 min |

Skill Tests takes about twice as long in the merge group (27.9 min median) as on the pull request (13.2 min median); § Workflow event coverage gives the reason.

## Failed merge-group runs

The PR column is the group's head PR, from `headBranch`; the run list does not name the other PRs in each group. Aggregator jobs (CI, Skill suites, Cargo workspace tests) fail as a consequence and are left out of the job column. Where a run has two causes, the class is the one that would have failed it on its own: real defect over limit over flake.

| Class | Runs | Failure signatures inside those runs | Carried by |
|---|---|---|---|
| Real defect | 24 | workflow-state-remove 19, oversee_watch_owed 5; doc-limits rides along in 17 of them, and a flake in 3 | KEN-2031 (the PR run never ran the macOS shards that caught them) |
| Self-inflicted limit | 15 | doc-limits alone 13, doc-limits plus a flake 2 | KEN-2039 |
| Flake or infra | 12 | lanes-cache 2, cargo-windows 2, oversee_succeed 2, orch-shard-partition 2, job_unit 1, lane-mail 1, open-terminal 1, oversee_watch_overseer 1, release-installer-check 1 | KEN-2043 to KEN-2047, KEN-2008; see the flake table |
| Cancelled | 11 | group requeued; not among the 51 | none |

### Real defect runs

| Run | Head PR | Created | Failed jobs (shard, os) | Reason |
|---|---|---|---|---|
| 36389236955 | #3051 | 09-28 06:59Z | orch-oversee macos | oversee_watch_owed: 9 rows read lane=none verdict=queue instead of lane=stopped |
| 36389867882 | #3047 | 07:06Z | Bot instructions; orch-oversee macos | same 9 rows; also doc-limits oversee.md 41030 > 40960 |
| 36390819817 | #3057 | 07:16Z | Bot instructions; orch-oversee macos | same |
| 36391573659 | #3055 | 07:25Z | Bot instructions; orch-oversee macos; orch-terminal macos | same, plus open-terminal codex relaunch line captured empty (flake) |
| 36391720377 | #3055 | 07:27Z | Bot instructions; orch-oversee macos | same |
| 36405733468 | #3062 | 09:47Z | Bot instructions; orch-state macos | workflow-state-remove control "without the close-out archive the removed evidence cannot be read back" returns rc=0 on BSD userland; doc-limits oversee.md 41335 |
| 36406753114 | #3061 | 09:57Z | Bot instructions; orch-state macos | same |
| 36407979479 | #3062 | 10:09Z | Bot instructions; orch-state macos | same |
| 36407981203 | #3061 | 10:09Z | Bot instructions; orch-state macos | same |
| 36408474167 | #3058 | 10:14Z | Bot instructions; orch-state macos | same |
| 36410489754 | #3059 | 10:34Z | Bot instructions; orch-state macos | same |
| 36410869066 | #3059 | 10:38Z | Bot instructions; orch-state macos | same |
| 36410871197 | #3064 | 10:38Z | Bot instructions; orch-state macos | same; doc-limits now also README.md 12308 > 12288 |
| 36411004325 | #3060 | 10:39Z | Bot instructions; orch-state macos | same |
| 36411108385 | #3062 | 10:40Z | orch-state macos | workflow-state-remove control only |
| 36411110191 | #3061 | 10:40Z | orch-state macos | same |
| 36411112329 | #3059 | 10:40Z | orch-state macos; guards-tools macos | same, plus rustup sync text in cargo metadata (flake) |
| 36411113719 | #3064 | 10:40Z | Bot instructions; orch-state macos | same; doc-limits README.md and oversee.md 41188 |
| 36411115673 | #3060 | 10:40Z | Bot instructions; orch-state macos | same |
| 36412256692 | #3062 | 10:52Z | orch-state macos | workflow-state-remove control only |
| 36412260474 | #3061 | 10:52Z | orch-state macos | same |
| 36412261843 | #3059 | 10:52Z | orch-state macos | same |
| 36412264341 | #3064 | 10:52Z | Bot instructions; orch-terminal macos; orch-state macos | same, plus doc-limits README.md, plus pi relaunch line captured empty (flake) |
| 36415229189 | #3060 | 11:22Z | Bot instructions; orch-state macos | same; doc-limits README.md |

Both real defects are macOS-only and repeated identically across consecutive groups. The oversee_watch_owed failure ran in 5 groups from 06:59Z to 07:27Z and then stopped. The workflow-state-remove control failed in 19 groups from 09:47Z to 11:22Z; the PR carrying that test, #3062 (KEN-1946, closeout archives item evidence), merged at 15:03Z. Every group that had #3062 queued ahead of it was ejected by it.

### Self-inflicted limit runs

| Run | Head PR | Created | Failed jobs | Reason |
|---|---|---|---|---|
| 36403022509 | #3051 | 09:21Z | Bot instructions | doc-limits: oversee.md 41335 > 40960 |
| 36405216466 | #3051 | 09:42Z | Bot instructions | same |
| 36407979084 | #3051 | 10:09Z | Bot instructions | same |
| 36415399635 | #3064 | 11:23Z | Bot instructions | doc-limits: README.md 12308 > 12288 |
| 36415401777 | #3060 | 11:23Z | Bot instructions | same |
| 36415403888 | #3058 | 11:23Z | Bot instructions | same |
| 36417733295 | #3067 | 11:47Z | Bot instructions | same |
| 36418064054 | #3051 | 11:50Z | Bot instructions; orch-state macos | same, plus dev_validate_run setsid grandchild missed SIGTERM (flake, fixed by KEN-2015 at 15:35Z) |
| 36419304360 | #3064 | 12:02Z | Bot instructions | README.md |
| 36419305918 | #3060 | 12:02Z | Bot instructions | README.md |
| 36419307071 | #3058 | 12:02Z | Bot instructions | README.md |
| 36419308338 | #3067 | 12:02Z | Bot instructions | README.md |
| 36421444387 | #3051 | 12:22Z | Bot instructions | README.md |
| 36421880980 | #3062 | 12:26Z | Bot instructions | README.md |
| 36422003548 | #3069 | 12:27Z | Bot instructions; orch-oversee ubuntu | README.md, plus oversee_watch_overseer exit 4 instead of 3 (flake) |

doc-limits fired in 32 of the 51 failed runs in total. Two documents caused it: skills/orch/workflows/oversee.md at 41030 to 41669 bytes against a 40960 ceiling (07:06Z to 10:40Z, exempted by #3066 at 10:52Z, split by #3072 at 17:32Z), and skills/orch/README.md at 12308 bytes against a 12288 ceiling, 20 bytes over (10:38Z to 12:27Z). Each PR's own tree stayed under the ceiling; the combined queue tree did not.

### Flake and infra runs

| Run | Head PR | Created | Failed job | Reason | Carried by |
|---|---|---|---|---|---|
| 36351666359 | #3020 | 09-27 21:25Z | orch-rest macos | job_unit: stop-job on a setsid record left 1 process alive (setsid timing) | no item |
| 36355561743 | #3022 | 22:31Z | orch-state macos | lanes-cache: 3 sub-tests expected "scanned" got "skipped" (mtime timing) | KEN-2044 |
| 36356832436 | #3018 | 22:53Z | orch-state macos | lanes-cache: 2 different sub-tests, same symptom | KEN-2044 |
| 36391769188 | #3055 | 09-28 07:27Z | orch-state ubuntu | lane-mail timing control read prompt:1 instead of late | reworked to a virtual clock in #3067 |
| 36400821766 | #3059 | 09:00Z | Windows cargo | `background_refresh_still_skips_a_busy_source_without_the_foreground_wait` wait-count assertion; 2 of 90 Windows runs | KEN-2043 |
| 36402068513 | #3059 | 09:12Z | orch-oversee-succeed ubuntu; guards-tools macos | oversee_succeed read `context-unmeasured reason=context-unread`; `tools/tests/orch-shard-partition.test.sh` read rustup's "syncing channel updates" text where `cargo metadata` output was expected | KEN-2045, KEN-2008 |
| 36405213282 | #3058 | 09:42Z | guards-tools macos | orch-shard-partition: rustup sync text in the `cargo metadata` read | KEN-2008 |
| 36419303596 | #3059 | 12:02Z | orch-terminal macos | open-terminal: pi relaunch `sessionDir` line captured empty | KEN-2046 |
| 36426487850 | #3062 | 13:08Z | orch-oversee-succeed ubuntu | oversee_succeed `context-unread` again; shard green in the groups between | KEN-2045 |
| 36431959398 | #3061 | 13:54Z | Windows cargo | same Windows wait-count assertion | KEN-2043 |
| 36447065403 | #3076 | 15:53Z | orch-oversee ubuntu | oversee_watch_overseer: watch dying in its long pass exited 4, launched=0 | KEN-2047 |
| 36458710891 | #3072 | 17:31Z | guards-tools macos | release-installer-check: `hdiutil attach` of the built .dmg failed on the runner; script unchanged in the window | no item |

Flakes also rode along in three real-defect runs (open-terminal at 07:25Z and 10:52Z, orch-shard-partition at 10:40Z) and in two self-inflicted runs (dev_validate_run at 11:50Z, fixed by KEN-2015; oversee_watch_overseer at 12:27Z). No failed run hit a shard timeout, a runner loss or a BSD tar defect.

## Workflow event coverage

Jobs are those of `.github/workflows/skill-tests.yml` unless named otherwise.

- pull_request only: the `preflight` and `markdown` jobs, and the whole `own-catalog` workflow (push and pull_request, no merge_group).
- merge_group only: the macOS legs of the Skill suites shards, which `tools/ci-job-set` lights on a pull request only where a lane source or another `.github/` path changed; the Review gate writer's merge-group leg, an unconditional green post.
- Both: the `changes` classifier, `bot-instructions` (which carries doc-limits and the todo-ban scan), the Linux legs of the Skill suites shards, `ui-tests`, `gate-selftest`, the Linux, macOS and Windows cargo jobs, `cargo-lint`, and the aggregators.
- Path filter on merge_group: the classifier runs on both events, reads the base and head from the merge-group payload, and selects shards from the group's diff. A stand-down skips a Linux shard when a passing PR run tested the identical tree.
- Stand-down in practice: in the 88 green queue runs each Linux shard still ran in 77 to 83 of them, so a moved base almost always defeats the reuse. macOS shards ran in 79 to 86 of 88.
- Slowest queue leg: the guards-tools macOS shard, median 25.3 min and max 29.6 min against its 30-minute timeout; it sets the queue's 27.9-minute median.

## Doc checks

What each doc check prevents, and on which event it runs. "Both" means pull_request and merge_group. KEN-2039 moves doc-limits and the todo-ban scan to pull_request only and keeps the bot-instructions and writer-equality checks on both. Owner directive 1790619146 B: a byte ceiling is a context budget, not a defect, and must never eject a group. `tools/tests/ci-aggregate.test.sh` holds the doc-limits, todo-ban and bot-instructions steps of `.github/workflows/skill-tests.yml` to the events in the "When it runs" column.

| Check | What it prevents | Where it runs on 2026-09-28 | When it runs |
|---|---|---|---|
| doc-limits | a document agents load grows past its class ceiling, and every session that reads it pays the context | `bot-instructions` job step, both events, growth margin (`--against`) on pull_request only; commit chain: first lane of pre-commit and pre-push | PR only (KEN-2039). The margin ([doc-limits policy § Growth margin](../../skills/doc-limits/references/policy.md#growth-margin)) fails the PR that grows a document near its ceiling. [doc-limits policy § Growth margin](../../skills/doc-limits/references/policy.md#growth-margin) owns when a document can still land on main over its ceiling. doc-limits scans the whole tree, so from then on every PR's doc-limits step and every commit-chain doc-limits lane fails until a change brings that document back under its ceiling. doc-limits fired in 32 of the 51 failed groups and was the only non-flake cause in 15 |
| todo-ban, index-wide scan | a work marker left in a tracked text file, which a reader trusts though nobody owns it | `bot-instructions` job step, both events | PR only (KEN-2039); hygiene, not a behaviour defect |
| md-refs and md-format | a relative link to a file that does not exist, or a hard-wrapped paragraph an agent reads half of | `markdown` job, pull_request only; commit-guards batch; pre-push sweeps the range | PR only, as today |
| bot-instructions check | a rendered review-bot instruction file that no longer equals what `kendex.toml` and the doctrine say, so every later PR is reviewed under rules nobody chose | `bot-instructions` job step `bot-instructions-check`, both events; pre-commit with `--staged`; hyprtrade CI with the default-branch checker | Both (KEN-2039): two PRs that each render cleanly against the base can merge into a `kendex.toml` whose render differs from the committed files, and the job runs in seconds under a 5-minute timeout |
| review-gate writer template equality (`skills/review-gate/scripts/validate-workflow.sh`, run by `validate.sh`) | an adopted writer workflow drifted from its template, so the gate writer misbehaves under an elevated token | `gate-selftest` job, both events; hyprtrade CI | Both (KEN-2039) |
| render-mirror rule (`tools/guard` key `missing-render`) | a skill source changed without its committed render, so this repository's own install runs the old copy and verify reports it stale | commit chain only: `COMMIT_GUARDS_PRE_COMMIT_LOCAL` and `tools/guard --full` at dev completion; no workflow runs it | Commit chain only; ejects no group. Under KEN-2038 it exempts `tests/` |
| decision-ids (`decisions check`, `tools/guard` full mode) | two decision records with one ID, so a citation resolves to the wrong decision | commit chain only | Commit chain only |
| prose lane (commit-guards batch) | history and narration in markdown agents load | commit chain only | Commit chain only |
| doc-drift-check (`hooks/doc-drift-check.sh`) | a changed path that no architecture topic covers | Stop hook, not a CI gate; reads `.kendex-generated.json` to skip renders | Stop hook only; KEN-2038 shrinks its inventory and changes nothing else |

## Method

- Counting rule: "N of M under" counts a pull request whose per-PR appendix value, in whole minutes, is at or below the row's target; M is the pull requests with a value in that column. One rule holds for every row.
- PR checks wall: `ci_head_secs`, first check-run start to last check-run end on the final head.
- Merge-group CI run: `ci_merge_group_secs`, the same span over the merge commit's merge_group runs.
- Merge queue: `queued` stamp to `merged` stamp.
- Open to merge: `open_secs`, created to merged.
- Main blocker: the longest gap between consecutive stamps among `created`, `last_push`, `ci_green`, `gate_met`, `queued` and `merged`, named by the stamp that ends it. `last_push` is the review-and-fix loop before the final push, `ci_green` the checks on the final head, `gate_met` the review gate, `queued` the wait between green and queue entry, and `merged` the merge queue. `last_push` is the final head's push, its first check suite, or the last force push where that is later. Where a pull request's final head arrived by a normal push, the 94 above were measured from that head's committer date, which predates the push by any wait before it, so those pull requests' `last_push` gaps end early and their `ci_green` gaps start early. Where the final head arrived by a force push, the old reading already took the push time.
- Review stage: the `rounds` list `pr-timeline` reads, which the cycle record carries as `pr_rounds`. A review round runs from a head's push, the creation of the head's first check suite, to the first review of that head by anyone but the pull request's author. A fix round runs from that review to the next push. The author's own reviews are thread replies and end no round. `oversee-cycle rollup` gives each class its median review rounds per pull request, its median seconds per review round and its median seconds per fix round. The lane's local reviewer rounds, which GitHub never sees, stay in the lane's workflow state and are not in these rows.

## Per-PR appendix

One row per pull request in the set, class from its cycle row.

| PR | item | class | open to merge (min) | PR checks wall (min) | merge-group CI (min) | queue (min) | longest gap ends at |
|---|---|---|---|---|---|---|---|
| 2801 | KEN-1493 | standard | 7012 | 13 | 26 | 26 | last_push |
| 2884 | KEN-1765 | standard | 3787 | 13 | 20 | 21 | last_push |
| 2941 | KEN-1829 | standard | 1008 | 13 | 22 | 23 | last_push |
| 2949 | KEN-1850 | standard | 404 | 10 | 22 | 22 | last_push |
| 2952 | KEN-1849 | standard | 780 | 24 | 21 | 21 | last_push |
| 2954 | KEN-1639 | standard | 663 | 11 | 22 | 22 | last_push |
| 2955 | KEN-1872 | standard | 677 | 12 | 19 | 19 | last_push |
| 2960 | KEN-1847 | standard | 580 | 12 | 20 | 21 | last_push |
| 2961 | KEN-1661 | standard | 1242 | 13 | 24 | 25 | last_push |
| 2962 | KEN-1873 | small | 873 | 22 | 20 | 20 | last_push |
| 2963 | KEN-1844 | standard | 917 | 12 | 21 | 22 | last_push |
| 2964 | KEN-1880 | standard | 110 | 25 | 22 | 22 | last_push |
| 2966 | KEN-1533 | standard | 115 | 12 | 24 | 24 | last_push |
| 2967 | KEN-1731 | standard | 268 | 12 | 24 | 25 | last_push |
| 2968 | KEN-1824 | standard | 178 | 11 | 28 | 28 | last_push |
| 2970 | KEN-1732 | standard | 34 | 12 | 21 | 22 | merged |
| 2971 | KEN-1722 | standard | 619 | 10 | 24 | 25 | last_push |
| 2972 | KEN-1885 | standard | 32 | 10 | 21 | 22 | merged |
| 2973 | KEN-1779 | standard | 34 | 12 | 22 | 22 | merged |
| 2974 | KEN-1882 | standard | 104 | 11 | 20 | 21 | last_push |
| 2975 | KEN-1883 | standard | 54 | 10 | 23 | 23 | merged |
| 2982 | KEN-1886 | standard | 239 | 11 | 24 | 24 | last_push |
| 2984 | KEN-1881 | standard | 36 | 11 | 24 | 25 | merged |
| 2987 | KEN-1877 | standard | 71 | 21 | 22 | 22 | last_push |
| 2988 | KEN-1894 | standard | 193 | 12 | 23 | 31 | last_push |
| 2990 | KEN-1505 | standard | 146 | 12 | 23 | 24 | last_push |
| 2997 | KEN-1825 | standard | 43 | 13 | 23 | 24 | merged |
| 3000 | KEN-1899 | standard | 49 | 12 | 24 | 24 | merged |
| 3001 | KEN-1878 | standard | 32 | 11 | 21 | 21 | merged |
| 3002 | KEN-1933 | standard | 42 | 12 | 22 | 22 | merged |
| 3004 | KEN-1922 | standard | 63 | 22 | 20 | 21 | merged |
| 3005 | KEN-1932 | standard | 77 | 13 | 25 | 26 | last_push |
| 3006 | KEN-1902 | standard | 661 | 13 | 21 | 22 | last_push |
| 3008 | KEN-1937 | standard | 42 | 13 | 24 | 25 | merged |
| 3010 | KEN-1779 | standard | 120 | 21 | 25 | 26 | last_push |
| 3011 | KEN-1942 | standard | 81 | 13 | 22 | 23 | last_push |
| 3012 | KEN-1928 | standard | 180 | 36 | 26 | 27 | last_push |
| 3013 | KEN-1887 | standard | 145 | 12 | 27 | 28 | queued |
| 3014 | KEN-1893 | standard | 345 | 13 | 21 | 22 | last_push |
| 3015 | KEN-1888 | standard | 70 | 13 | 20 | 21 | ci_green |
| 3016 | KEN-1945 | standard | 71 | 11 | 21 | 21 | last_push |
| 3017 | KEN-1947 | standard | 42 | 10 | 24 | 25 | merged |
| 3018 | KEN-1950 | standard | 156 | 11 | 22 | 28 | last_push |
| 3020 | KEN-1944 | standard | 75 | 13 | 29 | 30 | queued |
| 3021 | KEN-1890 | standard | 84 | 56 | 20 | 20 | ci_green |
| 3022 | KEN-1938 | standard | 212 | 19 | 24 | 25 | last_push |
| 3023 | KEN-1956 | standard | 115 | 12 | 23 | 24 | last_push |
| 3024 | KEN-1963 | standard | 145 | 26 | 22 | 23 | last_push |
| 3025 | KEN-1968 | standard | 33 | 13 | 19 | 20 | merged |
| 3026 | KEN-1845 | standard | 162 | 31 | 25 | 26 | last_push |
| 3030 | KEN-1943 | standard | 47 | 10 | 22 | 23 | merged |
| 3035 | KEN-1971 | standard | 46 | 23 | 21 | 22 | merged |
| 3036 | KEN-1968 | small | 38 | 13 | 25 | 26 | merged |
| 3037 | KEN-1968 | standard | 58 | 28 | 21 | 21 | ci_green |
| 3038 | KEN-1965 | standard | 39 | 13 | 21 | 21 | merged |
| 3039 | KEN-1925 | standard | 43 | 13 | 26 | 26 | merged |
| 3041 | KEN-1939 | standard | 40 | 13 | 24 | 25 | merged |
| 3042 | KEN-1984 | standard | 42 | 12 | 25 | 25 | merged |
| 3043 | KEN-1983 | standard | 54 | 25 | 26 | 27 | merged |
| 3044 | KEN-1923 | standard | 322 | 28 | 26 | 26 | last_push |
| 3045 | KEN-1958 | standard | 53 | 12 | 27 | 28 | merged |
| 3046 | KEN-1975 | standard | 41 | 13 | 21 | 23 | merged |
| 3047 | KEN-1966 | standard | 163 | 13 | 26 | 48 | last_push |
| 3048 | KEN-1991 | standard | 45 | 16 | 25 | 26 | merged |
| 3049 | KEN-1992 | standard | 45 | 10 | 13 | 18 | merged |
| 3051 | KEN-1982 | standard | 459 | 13 | 37 | 133 | last_push |
| 3052 | KEN-1967 | standard | 40 | 13 | 24 | 25 | merged |
| 3053 | KEN-1969 | standard | 46 | 13 | 29 | 29 | merged |
| 3054 | KEN-1960 | standard | 132 | 14 | 29 | 29 | last_push |
| 3055 | KEN-1989 | standard | 111 | 12 | 27 | 28 | queued |
| 3056 | KEN-1990 | standard | 226 | 13 | 25 | 73 | last_push |
| 3059 | KEN-1973 | standard | 258 | 13 | 34 | 169 | merged |
| 3060 | KEN-1995 | standard | 351 | 29 | 29 | 105 | queued |
| 3061 | KEN-1948 | standard | 373 | 28 | 30 | 45 | queued |
| 3062 | KEN-1946 | small | 329 | 13 | 30 | 33 | last_push |
| 3063 | KEN-1993 | standard | 194 | 14 | 25 | 26 | last_push |
| 3064 | KEN-1985 | standard | 181 | 13 | 37 | 164 | merged |
| 3065 | KEN-1935 | standard | 289 | 14 | 33 | 36 | last_push |
| 3067 | KEN-1738 | micro | 151 | 14 | 43 | 137 | merged |
| 3069 | KEN-1997 | standard | 158 | 13 | 25 | 141 | merged |
| 3070 | KEN-2006 | standard | 155 | 11 | 38 | 143 | merged |
| 3071 | KEN-2007 | micro | 161 | 9 | 15 | 133 | merged |
| 3072 | KEN-2003 | standard | 317 | 14 | n/a | admin merge | last_push |
| 3074 | KEN-1987 | standard | 286 | 14 | n/a | admin merge | last_push |
| 3076 | KEN-2005 | standard | 213 | 14 | 25 | 37 | last_push |
| 3077 | KEN-2014 | standard | 207 | 31 | 29 | 30 | queued |
| 3078 | KEN-2015 | micro | 137 | 14 | 29 | 56 | merged |
| 3080 | KEN-1952 | small | 47 | 14 | 27 | 33 | merged |
| 3081 | KEN-1949 | standard | 217 | 13 | n/a | admin merge | last_push |
| 3083 | KEN-1951 | standard | 58 | 12 | 29 | 46 | merged |
| 3084 | KEN-1957 | standard | 55 | 15 | 22 | 23 | merged |
| 3086 | KEN-2025 | standard | 84 | 16 | 22 | 59 | merged |
| 3089 | KEN-2040 | small | 19 | 13 | n/a | admin merge | queued |
| 3092 | KEN-2025 | standard | 94 | 67 | 3 | 1 | ci_green |
