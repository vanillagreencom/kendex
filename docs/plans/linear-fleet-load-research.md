# Findings: Linear fleet load, guard parity, fields and freshness

## Research Question

Every lane, VM overseer and local overseer reads and writes Linear as one application actor, so the whole fleet shares one rate-limit bucket. What does each workflow cost in requests and complexity points, with the cache and without it? How much headroom does the fleet have at peak concurrency? Which rules do the `linear.sh` commands enforce that a raw GraphQL route must keep? Which output fields does each caller read? How do the commands plus the skill compare with the raw route plus the rule text it needs? How can data stay fresh without polling? The answer decides whether the cache stays, changes or goes.

## Executive Summary

Drop the cache. On the live-read route KEN-2335 specifies, with each cache read a workflow names priced as its live command, one lane costs 40 requests and 16,083 complexity points from launch to close. Today's lanes are close to that but not on it: they start with no cache seed (fleet FLT-641 removed it), run no `sync --reconcile` (directive 1790845185) and read issues live where the launch briefs say so, but scripts that read the cache get no answer. `branch-size-check` exits 2 at each of its three calls; the launch-time one stops `start-worktree.md`, and today's hosted lanes go on only under fleet ruling gen81. Under that ruling today's lane costs 38 requests and 15,305 points, and a TPM audit pays a full sync (§ Today). The with-cache figures come from the sync-query runs and the scratch syncs made under owner exception 1791058163. With a warm cache it costs 247 requests and 184,090 points, because each of its five syncs pays the fixed phases again. On an empty cache the first sync is full and the lane costs 436 requests and 306,515 points. [M]

- A full sync, measured end to end, costs 207 requests and 134,475 points in 711 seconds without attachments, and 234 requests and 158,100 points with the 27 attachment pages. A sync on a fresh seed costs 7 requests and 10,810 points in 7 seconds, and 34 requests and 34,435 points with the attachment pages. [M] runs `seed-full`, `seed-incremental`, `sync-attachments`
- Peak: the four overseer watches, one per fleet at `--interval 900`, cost 132 requests and 45,584 points an hour. All 38 lanes at the fleets' caps (kendex 20, fleet 12, vg 3, talk 3), each running its whole life in one hour, plus the watches and one TPM audit, use 1,727 requests (34.5 percent) and 713,053 points (35.7 percent) of the shared bucket on the live-read route, and 1,813 (36.3 percent) and 785,528 (39.3 percent) as lanes and the audit run today. Started at once, with each start's syncs back to back at their measured pace and the bucket refilling as it drains, 20 warm lane starts exhaust the complexity bucket 95 seconds in, which is kendex's cap; on empty caches 11 do, 786 seconds in (10 without drovr's rows). [M] [O]
- In a 70-minute window with no other request from this sandbox, in today's state, the shared request bucket never fell below 4,994 of 5,000, and the complexity bucket never below 1,915,628 of 2,000,000. The control host logged no RATELIMITED line in 7 days. [M] [O]
- Reconcile fails before its first request in this workspace: the 6,488 cached ids make one 272,580-byte jq argument, past Linux's 128 KiB limit (KEN-2667). A plain `sync` reconciles by itself when the reconcile stamp is missing or an hour old, and only `sync --full` writes the stamp, so the sync after a missing-cache full sync fails. The launch briefs' stop on `--reconcile` does not stop it, and 20 workflow, skill and reference files still name `sync --reconcile`. [L5] [T2]
- A restored seed makes a lane's first sync incremental, but one seeded sync still costs 2.1 times the points of a whole lane without the cache. The recommendation stays drop; § Lane cache seed gives the design and its owner. [M]
- Nine of the twelve rules the commands enforce have no owner on a raw route, and seven of them become regressions. KEN-2335's thin layer must keep five of them in code: the team target, the agent label and reach lines on create, peer-only blocking relations, and the validate-completion matrix. [L1] [L2] [L3]
- Freshness: no cache, with live reads, costs the least and needs no new owner. A webhook-fed cache needs a public HTTPS receiver and the `admin` scope, which the kendex app does not hold. [S2] [L4]
- Drovr is archived and its Linear team was recreated empty, so no consumer, fleet or concurrency figure counts it. The measured full sync still read drovr's 432 issues and 848 comments; without them it costs 225 requests and 152,190 points, and the empty-cache threshold falls from 11 starts at once to 10 (§ Drovr). [M]
- Team-limited write credentials (KEN-2689) should be one OAuth app per team, not personal keys. Personal keys all share the owner's 2,500 requests an hour, and the fleet's peak hour plus the cross-team read key needs 1,781 of them on the live-read route (71.2 percent) and 1,867 as lanes run today (74.7 percent). One app per team gives each team its own 5,000; kendex at its cap needs 943 (18.9 percent) or 1,065 (21.3 percent). [M] [D1]

§ Sync runs during this research lists every sync this research ran and its share of each bucket.

## Key Findings

- **Each sync is a fixed cost, paid before any read.** A plain sync with no changed issue still reads projects (8,805 points), cycles, labels and three failing initiative requests: 7 requests and 10,810 points (run `seed-incremental`). With the 27 attachment pages it is 34 requests and 34,435 points, more than the 16,083 points a whole lane spends on the live-read route without the cache. [M] [L5]
- **Reconcile fails in this workspace, and plain sync runs it.** `reconcile_issues` puts every cached id into one variables string (`sync.sh:529,545`), which `graphql_query` hands to jq as one argument (`common.sh:259`). At 6,488 ids that argument is 272,580 bytes and jq exits 126, "Argument list too long"; 3,000 ids (117,029 bytes) pass (local test, no request). A plain `sync` reconciles whenever the reconcile stamp is missing or over 60 minutes old (`sync.sh:819-828`, `:471-472`). Only `sync --full` writes the stamp: a full sync that runs because the cache is missing leaves it null (`sync.sh:624`, `:678`, `:863-866`, `:879`). So the plain sync after `session-status` builds a cache fails, and every one after it. [M] `argv_test` [L5] [T1] [T2]
- **`session-status` runs a full sync on a missing cache.** `session-status.sh:66-70` runs `sync.sh` whenever the cache is missing or older than 15 minutes; `audit-issues.md:57` and `tpm-cycle-plan.md:10` call it. A lane has had no cache since FLT-641, so its first call pays a full sync (KEN-2693). This research triggered it once, at 20:13Z. [M] [L6] [T3] [T6]
- **The app token cannot read initiatives.** Linear answers HTTP 400 "Invalid scope: `initiative:read` or `initiative:write` required". `graphql_query` retries every non-200 answer, so each failed read costs 3 requests (`skills/linear/scripts/lib/common.sh:345-363`). Every sync and `initiatives list` fail this way; both scratch syncs at 22:04Z logged it. `roadmap-create`'s two live initiative writes (`roadmap-create.md:62`, `:71`) were not measured. [M] [L1]
- **The overseer watch window grows every day.** The new-issue read lists every issue the team created since the watch's fixed `--since`, rounded up to whole days (`oversee-watch:1318-1323`), with every field, to use `id` and `created_at`. The kendex watch, started with `--since 2026-09-16T00:32:11Z`, reads 1,168 rows in 17 requests, 6,209 points and 5.6 MB on each pass (run `watch-pass-kendex-18d`). A trimmed read at 250 rows per page answers a 1-day window in 1 request at 4 points (run `watch-created-trim-1d`). [M] [L7] [O]
- **Live commands write the cache, reads included.** A worktree's `.cache` links to the base checkout's (`kendex.settings.toml:363`, `cache.sh:65`), so the 20:13Z sync wrote the base checkout's cache, and the directory there now dates from 21:53:22.556Z, half a second after a live `comments create` sent from this worktree (§ Sync runs; KEN-2695). This research's live `comments list` reads on 2026-10-03 at about 22:00Z wrote `comments/<ID>.json` into the read cache it pointed `LINEAR_CACHE_ROOT` at. [M] [L10] [T7]
- **Linear's rate-limit window does not reset hourly.** Every `X-RateLimit-Requests-Reset` header in [M] `runs` reads about 3,600 seconds after the request: 3,600.14 to 3,618.51, and 145 of the 151 rows that carry it within 3,600.14 to 3,600.35. The bucket refills at a constant 1.39 requests and 555.6 points per second, as the provider page states. [M] [S1]

## Evidence and Sources

### Method

- **Actor**: `linear.sh auth-check` reports credential `app-token`, actor kind `application`, id `f9755405-2f06-46a6-b706-1f552ff74bef`, name `vanillagreen agents`, team `kendex`. Headers report 5,000 requests and 2,000,000 points. The overseer's answer reports the same credential and actor id in all four fleets' base checkouts, so every fleet, overseer and lane shares this one bucket. [M] [O]
- **Command runs**: each `linear.sh` command ran with a logging `curl` shim first on `PATH`. The shim adds `-D` to the real `curl`, keeps the operation name, and drops the Authorization line and the variables. Each call is one row in [M] `calls`, keyed by its run id: the request time plus the command label. [M]
- **Plain reads**: `probe.sh` posts one GraphQL document with the credential `linear.sh` selects (`skills/linear/scripts/lib/auth.sh:65-71`) and records every `X-RateLimit-*` header and `X-Complexity`. `sync-price.sh` sources `sync.sh` and runs each sync function with `graphql_query` replaced by the same recorder; no cache file is written. Each request is one row in [M] `runs`, keyed by its run id. [M]
- **Scratch syncs**: under exception 1791058163, real `linear.sh sync` runs with `LINEAR_CACHE_ROOT` set to a directory under this worktree's `tmp/`, Linear reads only, every request through the shim. [M] `sync_runs`
- **Sampler**: `{ viewer { id } }` every 120 seconds from 20:10:16Z. Each sample costs 1 request and 1 point. [M] `runs` rows whose id ends `-sample`.
- **Control host**: the overseer's answer to lane-mail ask 1791058128-12831-9940, read on the control VM at about 20:10Z. [O]
- **Base**: kendex `ef4100c734d4fde4e8d48ee5479fc4df999e65b6`. Source citations name files at that commit. Date 2026-10-03.

### Bucket behaviour

| Quantity | Value | Source |
|---|---|---|
| Request bucket | 5,000, refill 5,000 per 3,600 s | [M] headers; [S1] "leaky bucket", "refilled with a constant rate of `LIMIT_AMOUNT / LIMIT_PERIOD`" |
| Complexity bucket | 2,000,000, refill 2,000,000 per 3,600 s | [M] headers; [S1] |
| Per-query cap | 10,000 points | [S1] |
| Reset header | Request time plus about 3,600 s: 3,600.14 to 3,618.51 s; 145 of 151 rows within 3,600.14 to 3,600.35 | [M] `runs` rows that carry `req_reset`; `calls` rows carry no reset header |
| Rate-limit answer | HTTP 400, `errors[].extensions.code` `RATELIMITED` | [S1]; `skills/linear/scripts/lib/common.sh:280-290` |
| Header noise | Remaining moved up by 21 between two calls 0.3 s apart | [M] run `20261003T203126988-sync-projects-full-p1`, 4,960 then 4,981 |

A workload uses the complexity bucket first when it spends more than 400 points per request, the ratio of the two buckets.

### Per-call prices

| Command, as a workflow calls it | Requests | Points | Body bytes | Run label in [M] |
|---|---|---|---|---|
| `issues activate --agent researcher` | 6 | 1,192 | 16,983 | `activate` |
| `auth-check` | 1 | 2 | 113 | `auth-check` |
| `teams get kendex` | 2 | 252 | 2,690 | `teams-get` |
| `issues get` | 1 | 389 | 5,608 | `issues-get` |
| `issues get --with-bundle` | 1 | 1,518 | 5,548 | `issues-get-bundle` |
| `comments list` | 1 | 5 | 63 | `comments-list` |
| `comments create` | 1 | 5 | 2,716 | `comment-create`, run `2026-10-03T21:53:22.046Z-comment-create` |
| `issues validate-completion` on a leaf | 3 | 1,912 | 11,219 | `validate-completion` |
| `issues children --recursive` | 1 | 1,136 | 212 | `children` |
| `issues bulk-get` of 3 | 4 | 391 | 15,986 | `bulk-get` |
| `issues list --created-since 1d --max` (81 rows) | 3 | 833 | 227,618 | `watch-created-1d` |
| `issues list --created-since 3d --max` (354 rows) | 6 | 1,985 | 1,680,790 | `watch-created-3d` |
| `issues list --state "In Progress,In Review" --max` (20 rows) | 2 | 449 | 141,948 | `watch-owed` |
| `issues list`, four active states, `--max` (259 rows) | 5 | 1,601 | 1,244,467 | `tpm-active` |
| `issues list`, all six states, `--max` (2,613 rows) | 36 | 13,505 | 10,234,527 | `tpm-all` |
| `labels list` | 1 | 285 | 15,927 | `labels-list` |
| `projects list` | 1 | 5,870 | 68,815 | `projects-list` |
| `cycles list` | 2 | 418 | 2,351 | `cycles-list` |
| `initiatives list` | 3, all HTTP 400 | none reported | none | `initiatives-list` |
| `issues update --state` | 3 | 783 | | Derived: `GetIssue` 389, `GetState` 10, `UpdateIssue` 384, the measured parts of `activate`; `skills/linear/scripts/commands/issues.sh:1802,1951,2062` |
| `issues complete --done-when-met` | 4 | 1,172 | | Derived: one `get_issue` plus `issues update` (`skills/linear/scripts/commands/issues.sh:3135,3176`) |

A live list costs 1 team lookup plus one request per 75 rows (`skills/linear/scripts/commands/issues.sh:482-488`), at 384 points per page.

### Sync prices

Full sync, measured end to end: `linear.sh sync --full --no-attachments` into a scratch cache, 22:04:13Z to 22:16:04Z, 711 seconds, 6,496 issues and 45 projects kept. [M] run `seed-full`

| Phase | Requests | Points | Rows | Source |
|---|---|---|---|---|
| Issues, every team, archived included, 75 per page | 93 | 35,805 | 6,496 live after the archive filter | Run `seed-full`, 385 points a page; the same 93 pages in labels `session-status` and `scratch-sync-full` |
| Comments, every team, 250 per page | 63 | 75,600 | 15,694 | Run `seed-full`, 1,200 points a page; the same in label `scratch-sync-full` |
| Projects, 75 per page | 1 | 8,805 | 45 | Run `seed-full` |
| Project dependencies, one request per project | 45 | 12,645 | | Run `seed-full`, 281 points each |
| Cycles, team filter | 1 | 395 | 7 | Run `seed-full` |
| Initiatives | 3 | none | 0, HTTP 400 scope error | Run `seed-full`; 3 attempts from `common.sh:345-363` |
| Labels | 1 | 1,225 | 63 | Run `seed-full` |
| **Measured total, no attachments** | **207** | **134,475** | | |
| Attachments, every page, on every sync without `--no-attachments` | 27 | 23,625 | 6,655 | Runs `sync-attachments`, 875 points each |
| **Total as `session-status` runs it** | **234** | **158,100** | | 207 + 27; 134,475 + 23,625 |

Run `sync-projects-full` read 55 project dependencies at 20:31Z, which would make the full sync 244 requests and 160,910 points; the end-to-end run read 45. Every figure below uses the end-to-end run.

An incremental sync reads each delta and every fixed phase again. [M] [L5]

| Phase | Requests | Points | Measured on |
|---|---|---|---|
| Issues changed since the last sync | 1 per 75 changed | 385 per page | 0 changed: run `seed-incremental`; 1 in 4 min, 26 in 60 min: runs `sync-issues-delta-4m`, `-60m` |
| Comments on those issues | 1 per 250, only when an issue changed | 1,200 per page | 3 and 71 comments: runs `sync-comments-delta-*` |
| Projects changed | 1, plus 1 per changed project | 8,805 per page, 281 per project | 0 changed: run `seed-incremental`, runs `sync-projects-delta-*` |
| Cycles, initiatives, labels | 5 | 1,620 | Run `seed-incremental` |
| **Measured, no change, no attachments** | **7** | **10,810** | Run `seed-incremental`, 7 seconds |
| Attachments | 27 | 23,625 | Runs `sync-attachments` |
| Reconcile, forced or last one over 60 min old | 10 at the cap as priced | 4 per page | Runs `reconcile-2613`; fails before any request in this workspace (§ Why lanes stopped syncing) |

| Incremental sync | Requests | Points | Derivation |
|---|---|---|---|
| No change, with attachments | 34 | 34,435 | 7 + 27; 10,810 + 23,625 |
| One change, with attachments | 35 | 35,635 | 34 + 1 comments page; 34,435 + 1,200 |
| One change, reconcile at 10 pages | 45 | 35,675 | 35 + 10; 35,635 + 40 |
| `sync --if-stale 15` on a cache under 15 minutes old | 0 | 0 | Run `seed-if-stale`; `sync.sh:653-656` |

Attachment downloads go to `uploads.linear.app`, not the GraphQL API; their count and limit were not measured.

### Drovr

Drovr is archived on GitHub and its Linear team was recreated empty (owner note 1791065386, overseer directive 1791065479-1890992-11565). It is no live consumer, and no consumer, fleet or concurrency figure counts it: the four fleets are fleet, talk, kendex and vg. [O] The measured syncs still read its rows, because a sync reads every team. The per-team counts from the 20:13Z and 20:19Z pulls give drovr 432 live issues and 848 comments, out of 11 teams. [M] `counts`

| Figure | With drovr, as measured | Without drovr | Derivation |
|---|---|---|---|
| Teams | 11 | 10 | [M] `counts.issues_by_team` |
| Live issues, 20:13Z pull | 6,478 | 6,046 | 6,478 − 432 |
| Comments, 20:24Z pull | 15,694 | 14,846 | 15,694 − 848 |
| Full sync issue pages: requests / points | 93 / 35,805 | 87 / 33,495 at most | ⌈(6,496 live + 439 archived − 432) / 75⌉ = 87, at 385 points; the 439 archived rows are the count the run's summary line printed, [M] `sync_runs` `seed-full` `archived_filtered`; drovr's archived issues were not counted, so 87 is an upper bound |
| Full sync comment pages | 63 / 75,600 | 60 / 72,000 | ⌈14,846 / 250⌉ = 60, at 1,200 points |
| Full sync, no attachments | 207 / 134,475 | 198 / 128,565 | 207 − 6 − 3; 134,475 − 2,310 − 3,600 |
| Full sync with the 27 attachment pages | 234 / 158,100 | 225 / 152,190 | Attachment pages kept at 27; drovr's share of them was not measured |
| Empty-cache lane start | 326 / 229,702 | 317 / 223,792 | 2 + 225 + 90; 252 + 152,190 + 71,350 |
| Empty-cache lane | 436 / 306,515 | 427 / 300,605 | 436 − 9; 306,515 − 5,910 |
| Empty-cache TPM audit sync and `reconcile-work-items` | 234 / 158,100 | 225 / 152,190 | As the full sync |
| Empty-cache starts at once that exhaust a bucket, time-resolved | 19 / 11 | 18 / 10 | The § Peak concurrency and headroom simulation, with the last 6 issue pages and last 3 comment pages of run `seed-full` removed and their time closed up |
| All 38 lanes starting on empty caches | 12,388 / 8,728,676 | 12,046 / 8,504,096 | 38 × 317; 38 × 223,792 |
| Peak hour, 38 empty-cache lanes | 16,568 / 11,647,570 | 16,226 / 11,422,990 | 38 × 427; 38 × 300,605 |
| Today's TPM audit | 237 / 158,354 | 228 / 152,444 | 225 + 3; 152,190 + 254 |
| Today's peak hour at the caps | 1,813 / 785,528 | 1,804 / 779,618 | 1,444 + 132 + 228; 581,590 + 45,584 + 152,444 |
| Today's peak hour on personal keys, with the read key | 1,867 | 1,858 | 1,804 + 54 |
| Today's kendex peak hour on its own app | 1,065 / 489,290 | 1,056 / 483,380 | 760 + 68 + 228; 306,100 + 24,836 + 152,444 |
| Batched reconcile | 26 / 104 | 25 / 100 | ⌈(6,496 − 432) / 250⌉ = 25, at 4 points |
| Reconcile argv test | 6,488 ids fail | 6,056 ids still fail | More than twice the 3,000 ids (117,029 bytes) that pass, so past 234,058 bytes and the 131,072-byte limit |

The seed (55,525,696 bytes) includes drovr's rows; their share was not measured, and the scratch cache that held them is deleted. Elsewhere the empty-cache figures are the measured ones, with drovr's rows; this table gives each without them, and no conclusion changes. The no-cache and watch figures read no drovr row; the warm figures read drovr's ids only inside reconcile's 10 capped pages.

### Load per workflow

The first column is the live-read route KEN-2335 specifies: each read a workflow names is a cache read, which sends no request (for example `start.md:66`, `dev-start.md:25`, `merge-pr.md:162`), priced here as its live command, measured with the shim. The warm and empty columns are priced from the sync-query runs and the scratch syncs above. Today's lanes run neither: § Today, after the table, gives their figures.

One lane, one dev round, one review cycle, no fix rounds. The reads are the ones each workflow names at the cited line, as cache reads or as their live commands per column. "Warm" assumes a cache synced before the lane starts and a reconcile that works; "empty" is a host whose first sync is full. As the code stands, each `sync --reconcile` in the warm column fails in this workspace (§ Why lanes stopped syncing). [M]

| Workflow and its Linear calls | Live reads (KEN-2335 route), each cache read priced as its live command: req / points | Warm cache, priced: req / points | Empty cache, priced: req / points |
|---|---|---|---|
| Lane start: `open-terminal` `teams get` (`skills/orch/scripts/open-terminal:2985`); bundle read in `start.md` § 3 (`:66`), `start-worktree.md` § 1 (`:26`) and `dev-start.md` preflight (`:25`); launch size check `branch-size-check` (`start-worktree.md:85`, which reads `cache issues get` at `branch-size-check:280-283`); compact read in `dev-start.md` § 1 | 7 / 5,584 | 137 / 107,277 | 326 / 229,702 |
| Dev round: `dev-implement.md` § 2.1 sync, `activate`, issue and comment reads, completion comment; `dev-start.md` Check B `validate-completion` | 12 / 3,503 | 55 / 38,784 | 55 / 38,784 |
| Review: `branch-size-check` issue read (`review-pr.md:60`); panel Done-when read (`review-pr.md:65`); `qa-review.md` issue and comment reads | 4 / 1,172 | 0 / 0 | 0 / 0 |
| Submit: `branch-size-check` (`submit-pr.md:92`); title read (`:154`); `design` label read (`:214`); summary comment (`:419`) | 4 / 1,172 | 1 / 5 | 1 / 5 |
| Post-summary: `.blocks` read (`post-summary.md:71`), summary comment; In Review (`start-worktree.md:136`) | 5 / 1,177 | 4 / 788 | 4 / 788 |
| Merge and post-merge: children read (`merge-pr.md:162`), sync (`:316`), issue read (`:326`), `.parent_id` read (`:339`), `issues complete` (`:330`) | 7 / 3,086 | 49 / 36,847 | 49 / 36,847 |
| Lane close: `issues get` (`skills/orch/scripts/lane-close:515`) | 1 / 389 | 1 / 389 | 1 / 389 |
| **One lane** | **40 / 16,083** | **247 / 184,090** | **436 / 306,515** |
| Overseer watch, one long pass: new-issue read (`oversee-watch:1323`), each fleet's window | kendex 17 / 6,209; fleet 11 / 3,905; vg 3 / 833; talk 2 / 449 | Same: the watch reads live | Same |
| Four overseer watches, per hour at `--interval 900` | 132 / 45,584 | Same | Same |
| Overseer heartbeat: owed read (`oversee-watch:3569`), once per 25 long passes | 2 / 449 per read; 1.3 / 287 per hour for four watches | Same | Same |
| Cross-team read with the read key (KEN-2689), on the owner's personal bucket: per overseer pass with N cross-team blockers; per lane start whose issue names another team's issue | Pass: 1 / ⌈2.5 × N⌉, 0 with none; start: 1 / 3, 0 with none [D1] | Same | Same |
| TPM audit, team mode (`tpm-audit.md` § 1.1.1 to § 1.5) | 75 / 56,315 | 3 / 254 + one sync | 3 / 254 + 234 / 158,100 |
| `reconcile-work-items` | 36 / 13,505 | 0 + one sync | 234 / 158,100 |

Each cache read prices as a live `issues get`, 1 request and 389 points, the compact read as the same query; § Cache-read call sites lists every call site with its disposition. Each lane's three comment writes are in its request counts; their points are measured at 5 each (run `comment-create`). The warm lane is five syncs at 45 requests and 35,675 points plus its live calls; the empty lane replaces the first with the full sync, 234 and 158,100.

The audit without a cache reads the comparison list once (36 requests) and the team's comments as one connection: 29 pages of 250 for 7,119 kendex comments, each page 1,200 points (run `comments-team-page`). As written it also reads the four-state list separately, 5 requests that the six-state list already holds.

#### Cache-read call sites

Every cache read, sync and cache-reading script call in the files a model lane runs, from one mechanical sweep at `ef4100c7`: `git grep -nE 'cache (issues|comments|labels|projects|initiatives|cycles|attachments|status)|session-status|linear\.sh sync|\.cache/linear'` over `start.md`, `start-worktree.md`, `dev-start.md`, `dev-implement.md`, `dev-fix.md`, `review-pr.md`, `review-pr-comments.md`, `qa-review.md`, `submit-pr.md`, `post-summary.md`, `merge-pr.md` and the scripts `branch-size-check`, `container-close`, `reconcile-work-items`, `lane-close` and `open-terminal`, plus `git grep -nE 'scripts/(branch-size-check|reconcile-work-items|container-close|lane-close|open-terminal)'` over the same workflows for the script calls. It finds 33 lines; `review-pr-comments.md`, `lane-close` and `open-terminal` have none, and `container-close:215` is found through its call at `merge-pr.md:342`.

The model lane is one top-level issue that blocks nothing, delegated alone, with one dev round, one review cycle, no fix round and no pending children. Repeat reads: every call site the lane reaches is one read, even when an earlier step read the same issue. Each is its own command at its own line, and a script cannot reuse an agent's earlier result, so the rule applies to every pair alike: `review-pr.md:60` and `:65`, `submit-pr.md:154` and `:214`, `merge-pr.md:326` and `:339`.

| Call site | Read | Disposition | Live-read price |
|---|---|---|---|
| `start.md:65`, `start-worktree.md:25`, `dev-start.md:24`, `dev-implement.md:49`, `merge-pr.md:316` | `sync --reconcile` | The five syncs of the warm and empty columns; not run on the live-read route | 0 |
| `start.md:66` (§ 3) | `cache issues get --with-bundle` | Counted | 1 / 1,518 |
| `start-worktree.md:26` (§ 1) | `cache issues get --with-bundle` | Counted | 1 / 1,518 |
| `start-worktree.md:85` → `branch-size-check:281` | `cache issues get` | Counted | 1 / 389 |
| `dev-start.md:25` (preflight) | `cache issues get --with-bundle` | Counted | 1 / 1,518 |
| `dev-start.md:54` (§ 1) | `cache issues get --format=compact` | Counted | 1 / 389 |
| `dev-implement.md:19`, `:20` | `sync --reconcile`; parent read | Excluded: a bundled delegation only | |
| `dev-implement.md:51`, `:52` | issue read; comments read | Counted | 1 / 389; 1 / 5 |
| `dev-implement.md:65` | `cache comments bulk-list` of completed siblings | Excluded: bundled with completed siblings only | |
| `dev-implement.md:284` | `.blocks` read | Excluded: skipped when the issue blocks nothing (`:282`) | |
| `dev-fix.md:18`, `:19` | issue read; comments read | Excluded: no fix round | |
| `review-pr.md:60` → `branch-size-check:281` | `cache issues get` | Counted | 1 / 389 |
| `review-pr.md:65` | issue read for the panel's Done-when | Counted | 1 / 389 |
| `qa-review.md:29`, `:30` | issue read; comments read | Counted | 1 / 389; 1 / 5 |
| `submit-pr.md:92` → `branch-size-check:281` | `cache issues get` | Counted | 1 / 389 |
| `submit-pr.md:154` | issue read for the title | Counted | 1 / 389 |
| `submit-pr.md:214` | `cache issues get --format=compact` for the `design` label | Counted | 1 / 389 |
| `post-summary.md:71` | `.blocks` read | Counted | 1 / 389 |
| `merge-pr.md:162` (§ 4.1) | `cache issues children --pending --recursive` | Counted | 1 / 1,136 |
| `merge-pr.md:172` | issue read for a rebundle | Excluded: pending safe children only | |
| `merge-pr.md:326` | issue read | Counted | 1 / 389 |
| `merge-pr.md:339` (§ 6 step 2a) | `.parent_id` read | Counted; step 2b is skipped, since the issue has no parent | 1 / 389 |
| `merge-pr.md:342` → `container-close:215`, `:216`, `:262`, `:269` | `sync --reconcile`; parent read; children reads | Excluded: a container parent only | |
| `reconcile-work-items:58`, `:91` | A message naming `linear.sh sync`; `.cache/linear/issues.json` | Outside the lane: `audit-issues.md:59` runs it | |

Live commands the lane sends besides these: `open-terminal:2985` `teams get`, `activate`, `validate-completion`, the three comment writes, `issues update --state`, `issues complete` and `lane-close:515` `issues get`; each is in its row of the table above.

#### Today

Lanes have no cache today. The launch briefs have each agent read issues live where a workflow names a cache read; scripts cannot follow the briefs. [M]

| Today, no cache | Requests / points | Derivation |
|---|---|---|
| One lane, by the workflow text | Stops at launch after 4 requests and 3,288 points | `teams get` 2 / 252 and the `start.md` and `start-worktree.md` bundle reads, 2 / 3,036; then `branch-size-check` at `start-worktree.md:85` reads `cache issues get` (`branch-size-check:280-283`), exits 2 on no answer (`:205-209`), and `start-worktree.md:88` stops the workflow on exit 2 |
| One lane under fleet ruling gen81 | 38 / 15,305 | The ruling in each hosted lane's launch brief: record the size check as unavailable (`allowance_missing`) and go on, and state the diff measured with `git numstat` against the live issue's allowance in the PR body. The three `branch-size-check` calls send 0 requests: 40 − 3 and 16,083 − 3 × 389; the allowance read for the PR body is one live `issues get`, + 1 and + 389 |
| `reconcile-work-items` | 0, exits `missing-cache` | `reconcile-work-items:91` |
| TPM audit | 237 / 158,354 | `tpm-audit.md:44` runs `sync --if-stale 15`, a full sync on a missing cache: 234 / 158,100, plus `auth-check` and `teams get`, 3 / 254; `tpm-audit.md:60` forbids a live-only read |
| Peak hour at the caps under gen81, as § Peak concurrency and headroom builds it | 1,813 (36.3%) / 785,528 (39.3%) | 38 × 38 + 132 + 237; 38 × 15,305 + 45,584 + 158,354 |

### Why lanes stopped syncing

Each fact below was read at its source on 2026-10-03.

- **The stop came from KEN-2440.** Filed 2026-10-01 08:57Z from fleet overseer peer directive 1790844652: `sync --reconcile` failed with `jq: Argument list too long` on a 5,923-issue cache. Its cause section matches the source: `reconcile_issues` builds every cached id into `uuid_array` (`sync.sh:529`) and inlines it in one `$variables` string (`sync.sh:545`); `graphql_query` passes it as `--argjson variables` (`common.sh:259`), one argv word past the 128 KiB per-argument limit. The fix it asked for: batch the ids by 250. [T1] [L5] [L1]
- **KEN-2440 was canceled, not fixed.** Its comment of 2026-10-01T09:04:01Z cancels it under directive 1790845185 because KEN-2335 removes the cache, folds the lane-end call sites into KEN-2335, and states that lanes run no `sync --reconcile` and read issue state live with `issues get` until KEN-2335 lands. That comment calls the directive the owner's ruling; owner note 1791064681 corrects it: the directive came from the master session and stops only the lane-end `sync --reconcile`. [T1]
- **The bug is now KEN-2667.** Filed 2026-10-03 06:55Z from the VG-98 lane, state Triage: the same failure plus `Invalid GraphQL variables JSON` (the message `common.sh:261` prints), related to KEN-2335; KEN-2669 is its canceled duplicate. [T2]
- **It holds in this workspace.** The 6,488-id scratch cache makes a 272,580-byte variables argument; jq exits 126 with "Argument list too long". A 3,000-id argument (117,029 bytes) passes; a 250-id batch is 9,751 bytes. Local test, no request. [M] `argv_test`
- **Plain sync is incremental.** `sync.sh` help: "Incremental sync (or full if no cache)" (`sync.sh:31-33`); the full path runs only with `--full` or no `meta.json` (`sync.sh:678`). `--if-stale N` skips a cache younger than N minutes (`sync.sh:653-656`; run `seed-if-stale`, 0 requests). [L5] [M]
- **Plain sync still reconciles.** The incremental path reconciles when forced or when the reconcile stamp is missing or over 60 minutes old (`sync.sh:819-828`; `reconcile_is_fresh` at `sync.sh:466-479` returns 1 on an empty stamp at `:471-472`). Only `sync --full` writes the stamp: `full=true` is set by `--full` alone (`sync.sh:624`), the missing-cache full path runs with `full=false` (`sync.sh:678`), and `did_reconcile` exists only on the incremental path, so that sync reads the stamp from a `meta.json` that does not exist and writes it as null (`sync.sh:863-866`, `:879`). In this workspace the plain sync after such a full sync fails in reconcile, after its delta reads and before `meta.json` is written (`sync.sh:851-883`), so the next one fails the same way. A cache built by `session-status` (`session-status.sh:66-70`) is that case: the lane's next `session-status`, 15 minutes later, fails (KEN-2693's path). This is read from the source; no reconciling sync ran in this research. [L5]
- **FLT-641 removed the lane seed.** Fleet's FLT-641, Done, last updated 2026-10-01T20:13:55Z, removed `bin/lane_host/linear_cache.py` and its `create.py` caller and invariant 24 of fleet's lanes architecture document, so "a lane reads Linear live with its app token". FLT-642 records it as fleet 97f82a8, PR 642: "lane create seeds no Linear data". Since then a new lane's first sync is a full one. [T3] [T4]

Today's interim state, as one measured case: no seed, no reconcile, live reads where the briefs say so. Its load is § Today above (38 requests and 15,305 points a lane under fleet ruling gen81, the audit's full sync) and the § Fleet consumption sampler. Syncs still run where a script or workflow calls one that the launch briefs do not name: `session-status` on a missing cache, and the call sites below.

Every workflow, skill and script file that names a sync, at `ef4100c7`:

| Sync | Files and lines |
|---|---|
| `sync --reconcile`, workflow, skill and reference text (20 files) | `skills/dev/workflows/dev-implement.md:19`, `:49`; `skills/orch/workflows/dev-start.md:24`; `start.md:65`; `start-worktree.md:25`; `micro.md:39`; `handoff.md:21`; `merge-pr.md:316`; `skills/project-management/workflows/audit-issues.md:56`; `cycle-plan.md:10`, `:93`; `proposal-sweep.md:11`; `research-complete.md:12`; `research-issue.md:27`; `roadmap-create.md:12`, `:94`; `tpm-audit.md:60`; `tpm-roadmap-plan.md:31`; `skills/project-management/references/labels.md:19`; `skills/project-management/SKILL.md:75`; `skills/linear/SKILL.md:49`, `:86`, `:93`; `skills/linear/README.md:11`; `skills/linear/patterns/workflow-actions.md:47`. Source: `git grep -n 'sync --reconcile' ef4100c7 -- skills`, less the script and `skills/linear/tests/` |
| `sync --reconcile`, script | `skills/orch/scripts/container-close:215`, called at `:254`, `:265`, `:316` |
| `sync --if-stale 15` | `skills/project-management/workflows/research-spike.md:22`; `roadmap-plan.md:24`; `tpm-audit.md:44`; `skills/orch/scripts/lib/escapes.sh:138`, run by `oversee-report:756-787` |
| Plain `sync.sh` through `session-status` | `skills/linear/scripts/commands/session-status.sh:66-70`, called at `audit-issues.md:57` and `tpm-cycle-plan.md:10` |

If the cache stays, these files and the launch briefs must say the same thing. Today the briefs forbid what 20 files still tell an agent to run.

The keep-cache option needs all four fixes; each is priced for this workspace:

| Fix | Request and complexity cost | Source |
|---|---|---|
| Batched reconcile ids (KEN-2667) | 26 requests and 104 points per reconcile at 6,496 ids, against a failed sync today; 16 requests and 64 points above the 10-page price, so 80 and 320 more per warm lane | ⌈6,496 / 250⌉ = 26 pages at 4 points (runs `reconcile-2613`) |
| A reconcile stamp on every full sync, the missing-cache path included (`sync.sh:863`) | 0 requests; without it the plain sync after a `session-status` build reconciles at once | `sync.sh:624`, `:678`, `:863-866` |
| Restored lane seed (§ Lane cache seed) | First sync 34 requests and 34,435 points instead of 234 and 158,100 | Runs `seed-incremental`, `seed-full`, `sync-attachments` |
| `sync --if-stale N` at each workflow step, for long-running lanes | 0 requests when the cache is younger than N minutes, else one incremental sync, 34 to 35 requests and 34,435 to 35,635 points | Run `seed-if-stale`; incremental table above |

### Lane cache seed (design)

Design only; nothing is built. A lane starts from the overseer's cache, so its first sync is incremental, and a missing cache costs one incremental sync, not a full one (owner note 1791064681). KEN-2693 is the kendex-side defect: a lane with no cache pays a full sync on its first `session-status`. [T6]

Cost of a lane's first sync:

| Case | Requests | Points | Wall time | Source |
|---|---|---|---|---|
| No seed: full sync, as `session-status` runs it | 234 | 158,100 | 711 s without the attachment pages | Runs `seed-full`, `sync-attachments`; 225 / 152,190 without drovr's rows (§ Drovr) |
| Seed from a cache synced and reconciled within the hour, no changed issue | 34 | 34,435 | 7 s without the attachment pages | Runs `seed-incremental`, `sync-attachments` |
| Same, with 1 to 75 changed issues | 35 | 35,635 | | Plus one comments page, runs `sync-comments-delta-*` |
| Seed whose reconcile stamp is missing or over 60 minutes old, today | Fails after 2 or 3 delta requests | 9,190 to 10,390 spent | | Issues and projects pages, plus comments when an issue changed; § Why lanes stopped syncing |
| Same, with KEN-2667's batched reconcile | 60 to 61 | 34,539 to 35,739 | | 34 or 35 + 26; 34,435 or 35,635 + 104 |
| Each later step inside `--if-stale 15` | 0 | 0 | | Run `seed-if-stale` |

The seed directory was 55,525,696 bytes (55.5 MB) without attachments in the end-to-end scratch cache. Its two largest members were `issues.json`, 27,976,602 bytes, and the 5,520 comment files, 27,443,013 bytes, 55,419,615 together. Copying it sends no Linear request. [M] `scratch_deleted`

Two shapes:

1. **Copy at launch.** Lane create copies the control host's cache for that repository into the lane, as fleet did before FLT-641: `seed_linear_cache` archived `<host repo>/.cache/linear` into the sandbox, and FLT-183 made it skip `*.tmp` and `*.lock` entries and never fail the create on a read error. It needs a host cache synced and reconciled within the hour before each copy, with the reconcile stamp written (a host `sync --if-stale 60` costs 0 when fresh, else one incremental sync), KEN-2667's batched reconcile so that host sync does not fail once the hour has passed, and a lane cache root that is the lane's own so its writes stay in the lane (KEN-2695). [T3] [T5] [T7]
2. **Shared read-only cache.** Lanes read the overseer's cache in place and never sync. It needs the lane on the cache's host or a network mount: hosted lanes run in Daytona sandboxes, which the old seed reached only by an upload. It also needs commands that never write the shared cache, where today every live command writes it, reads included (KEN-2695), and an overseer that refreshes it, one incremental sync per refresh. A lane's freshness is then the overseer's refresh cadence. Lanes pay no sync. [T5] [T7] [M]

Owner: the seed is fleet's. FLT-641 removed it; a live search of fleet issues updated in the last 10 days for "seed", "linear cache" and `LINEAR_CACHE_ROOT` finds no item that restores it (FLT-642 only records the removal on the hub). If the owner keeps the cache, a new item in fleet's tracker must restore `seed_linear_cache` in `bin/lane_host/linear_cache.py` and its call in `create.py`, invariant 24 in fleet's lanes architecture document and the FLT-183 fixture rows, and add the host refresh before the copy. [T3] [T4] [T5]

Recommendation check against these figures and the corrected rule: drop still holds. A seeded lane's first sync costs 34 requests and 34,435 points, 2.1 times the 16,083 points of a whole lane without the cache, and the lane still sends its live writes. Without attachments a seeded sync is 7 requests and 10,810 points, 67 percent of a whole no-cache lane's points, paid again at every step past the `--if-stale` age. The corrected rule changes no figure: it stopped only the lane-end reconcile, and reconcile fails in this workspace either way.

### Peak concurrency and headroom

From the overseer's answer to lane-mail ask 1791058128-12831-9940, read on the control VM at about 20:10Z: [O]

| Load source | Count | Requests per hour | Points per hour | Source |
|---|---|---|---|---|
| VM overseer watches, `--repeat 60 --interval 900` | 4: fleet, talk, kendex, vg | 132 | 45,584 | [O]; 4 long passes an hour each, priced from runs `watch-pass-*`: kendex 4 × 17, 6,209; fleet 4 × 11, 3,905; vg 4 × 3, 833; talk 4 × 2, 449 |
| Local overseer watches | 0 | 0 | 0 | [O]: every overseer runs on the control VM |
| Hook-started single passes, `--interval 900 --max-loops 25` | 3 seen: fleet, vg, talk | 0 when they share the repeat watch's long-pass clock; 64 if not | 0; 20,748 if not | [O]; clock below |
| Heartbeat owed reads | One per 25 long passes per watch | 1.3 | 287 | `oversee-watch:3978`; 4 × 2 × 3,600 / (25 × 900); 4 × 449 × 3,600 / (25 × 900) |
| Cross-team reads with the read key (KEN-2689) | 4 watches × 4 passes; up to 38 lane starts | At most 54, on the owner's personal bucket of 2,500, not the app's | 16 × ⌈2.5 × N⌉ + 114, of 3,000,000 | [D1] § Read cost: 1 request per pass with a cross-team blocker, 1 request and 3 points per start; 16 + 38; 38 × 3 |
| Lane caps (`ORCH_OVERSEER_LANES`) | kendex 20, fleet 12, vg 3, talk 3; 38 in all; 11 kendex lanes live at the read | Per lane start: 7 without cache, 137 warm, 326 empty | 5,584; 107,277; 229,702 | [O]; § Load per workflow |
| Rest of each lane | Same caps | 33 without cache, 110 with cache | 10,499; 76,813 | § Load per workflow: the lane minus its start |
| One TPM audit | 1 | 75 without cache; 3 plus a sync with it | 56,315; 254 plus a sync | § Load per workflow |
| Recorded RATELIMITED answers | 0 `journalctl --user` lines matching "ratelimited" or "rate limited" in 7 days; overseer fleet-log rows mentioning a rate limit since 2026-09-26: kendex 6, fleet 41, vg 11, talk 7 | | | [O]; rows, not counted answers |

All four fleets set `LINEAR_TEAM` (kendex, fleet, vanillagreen, talk) and read as the same application, so one bucket serves them all. [O]

A long pass starts only when `--interval` has passed since the start recorded in the fleet's mail state (`oversee-watch:3849-3858`, row `long-pass` at `:285`). That state is keyed by the first repository and `--since` under the checkout's `tmp/oversee-watch` (`:255`, `:1205`), and a pass with no `--repo` takes the checkout's own repository (`:1158`). The hook passes run from the same base checkouts with the same `--state` and a `--since` that starts like the repeat watch's (the ps lines are cut off), so they most likely share the clock and add no long pass.

Burst load: lane starts at once, as the static sum of each start's requests and points against the 5,000-request and 2,000,000-point buckets. A sum over 100 percent is load, not exhaustion: a start spends its requests over time while the bucket refills. The last row is the time-resolved threshold.

| Lane starts at once | Without cache: req / points | Warm cache: req / points | Empty cache: req / points |
|---|---|---|---|
| kendex at 20 | 140 (2.8%) / 111,680 (5.6%) | 2,740 (54.8%) / 2,145,540 (107.3%) | 6,520 (130.4%) / 4,594,040 (229.7%) |
| fleet at 12 | 84 (1.7%) / 67,008 (3.4%) | 1,644 (32.9%) / 1,287,324 (64.4%) | 3,912 (78.2%) / 2,756,424 (137.8%) |
| vg or talk at 3 | 21 (0.4%) / 16,752 (0.8%) | 411 (8.2%) / 321,831 (16.1%) | 978 (19.6%) / 689,106 (34.5%) |
| All 38 | 266 (5.3%) / 212,192 (10.6%) | 5,206 (104.1%) / 4,076,526 (203.8%) | 12,388 (247.8%) / 8,728,676 (436.4%) |
| Starts at once that exhaust a bucket, time-resolved | 716 / 359 | 38 / 20 | 19 / 11 |

Each load figure is the count times the per-start cost above. The threshold row is time-resolved. Every start runs its reads back to back at the pace the shim logged: the full sync's 207 requests at their timestamps over 710 s (run `seed-full`), then the 27 attachment pages at their 0.60 s spacing (runs `sync-attachments`); each incremental sync as run `seed-incremental` (7 requests over 5.4 s, a mean gap of 0.89 s), with one comments page, 10 reconcile pages at the 0.94 s gap of runs `reconcile-2613` and the 27 attachment pages added. That makes a warm start 137 requests over 98 s, an empty start 326 requests over 793 s, and a no-cache start 7 requests over 4.8 s. The launch size check reads the cache in the warm and empty starts, so their timelines do not change. N starts begin together; the bucket starts full, refills at 1.39 requests and 555.6 points a second up to its cap, and loses N times each request's cost at that request's time. The threshold is the smallest N that takes the bucket below zero. Attachment downloads, which add time between pages, and the agent's work between a start's three syncs are left out, so a real start runs slower and each threshold is a lower bound. [M]

What the simulation gives at the caps, all starting at once:

| Fleet at its cap | Warm cache | Empty cache |
|---|---|---|
| kendex, 20 | Points exhausted 95 s in; requests stay above 2,395 | Both exhausted: points 289 s in, requests 780 s in |
| fleet, 12 | Neither: lowest 3,491 requests and 767,006 points | Points exhausted 762 s in; requests stay above 2,189 |
| vg or talk, 3 | Neither | Neither: lowest 4,659 requests and 1,711,236 points |
| All 38 | Both exhausted: points 53 s in, requests 97 s in | Both exhausted: points 199 s in, requests 254 s in |

Each 10 minutes of spread between starts adds 833 requests and 333,333 points of refill.

Peak hour on the live-read route, with every one of the 38 lanes running its whole life inside the hour: lanes 38 × 40 = 1,520 requests and 38 × 16,083 = 611,154 points, the four watches 132 and 45,584, one TPM audit 75 and 56,315. Total 1,727 requests (34.5 percent) and 713,053 points (35.7 percent); 1,791 and 733,801 (35.8 and 36.7 percent) if the hook passes keep their own clocks. As lanes and the audit run today under fleet ruling gen81 (§ Today): 38 × 38 = 1,444, 132 and 237, total 1,813 requests (36.3 percent); 38 × 15,305 = 581,590, 45,584 and 158,354, total 785,528 points (39.3 percent); 1,877 and 806,276 with the hook passes on their own clocks. The heartbeat adds 1.3 requests and 287 points. The read key bills the owner's personal bucket, not the app's: at most 54 requests an hour, 2.2 percent of its 2,500. With a cache the same hour needs 38 × 247 = 9,386 requests and 38 × 184,090 = 6,995,420 points warm, and 38 × 436 = 16,568 and 38 × 306,515 = 11,647,570 empty, before the watches.

The four fleets are the live consumers. Drovr is none and counts in no figure in this section; § Drovr gives the empty-cache figures without its rows.

Odds of a RATELIMITED answer, from a full bucket, with the complexity refill at 555.6 points a second:

- **Without cache**: no workload in the tables comes near either bucket. At the caps the peak hour uses about a third of each, on the live-read route and as lanes run today, and a burst needs 359 lane starts at once (time-resolved).
- **Warm cache**: certain when 20 lanes start at once, kendex's cap, 95 s in; 19 do not exhaust the bucket. Merges alone need 55 at once: a warm merge row is one sync plus `issues complete`, 49 requests and 36,847 points over 33 s, and the same simulation exhausts the bucket at 55.
- **Empty cache**: certain when 11 lanes start at once (10 without drovr's rows); the bucket runs out during their later syncs, 786 s in. A kendex or fleet relaunch at its cap does it; vg and talk at 3 do not.

### Fleet consumption

The sampler ran 98 minutes, 20:10:16Z to 21:48:45Z, 50 samples. From 20:38:22Z to 21:48:45Z, 70 minutes and 36 samples, this sandbox sent nothing to Linear but the samples; that is the clean window. [M] `fleet_consumption`; the samples are the `runs` rows whose id ends `-sample`

| Figure | Clean window | Whole run |
|---|---|---|
| Lowest requests remaining | 4,994 at 21:30:41Z | 4,834 at 20:10:08Z, before the first measurement |
| Samples at 4,998 or more | 35 of 36 | 46 of 50 at 4,995 or more |
| Lowest complexity remaining | 1,915,628 at 21:46:44Z | Same |
| Complexity gaps at a sample | 6 gaps: 7,668; 16,328; 752; 5; 84,372; 18,514 | |

The fleet's draw cannot be read as "remaining at the start minus remaining at the end". The bucket refills continuously and stops at its cap, and the reset header names no window (§ Bucket behaviour). While the bucket sits at its cap, any draw below the refill rate leaves no trace. What the headers show:

- The request bucket never fell below 99.8 percent in the clean window. The fleet's request draw stayed below the refill rate of 83 per minute for nearly all 70 minutes.
- The fleet drew at least 102,464 complexity points in the clean window. A sample's draw is the previous reading plus 555.6 points a second of refill, capped at 2,000,000, minus its own reading, less its own 1 point. Five samples show more than their own point: 16,327 at 21:04:28Z, 751 at 21:30:41Z, 4 at 21:44:44Z, 84,371 at 21:46:44Z and 1,011 at 21:48:45Z. The 18,514 gap at 21:48:45Z is mostly the earlier draw not yet refilled: 1,915,628 plus 66,870 of refill in 120.366 s gives 1,982,498, against 1,981,486 read. The 7,668 gap at the window's first sample, 20:38:22.950Z, is draw from before the window, 390 points of it this research's (label `context-bulk-get`, 20:36:24Z). The largest draw, 84,371 points, came inside the 120 seconds after 21:44:44Z. One heavy read, such as a full-backlog list or a sync-sized pull, explains it. [M] `fleet_consumption.clean_window`
- At 20:10:08Z the bucket stood 166 requests below its cap, of which this research had sent 1. Some caller drew at least 165 requests within the 2 minutes before.
- No sample came near either limit. In today's state, with lanes reading live, the odds of a RATELIMITED answer in this window were nil.

### Guard parity

Every rule the commands enforce today, and its owner on a raw GraphQL route.

| Rule | Where the command enforces it | Owner on a raw route | Verdict |
|---|---|---|---|
| Writes refuse with no team target | `lib/common.sh:241-245` (every mutation), `common.sh:626` | None. `issueCreate` needs a `teamId`, but nothing checks it is the configured team. | Regression |
| Create needs one `agent:*` label from `LINEAR_AGENT_LABELS` | `issues.sh:979-1011`, called at `issues.sh:1289` | None | Regression |
| Create needs a `Reached by:` line; review-born priority 2 needs `Symptom:` | `lib/issue-validation.sh:211-228`, called at `issues.sh:1290` | None | Regression |
| Blocking relations join peers only | `issues.sh:2507-2531`, `lib/issue-validation.sh:128-160` | None. Linear accepts any blocking relation. | Regression |
| `validate-completion` session-root, bundle and container rules | `issues.sh:3216` onward; help at `issues.sh:200-221` | None. KEN-2676 requirement 3 moves the rule to skill text. | Regression unless it stays code |
| Exclusive label groups | Linear rejects the write; `common.sh:301` rewrites the message | Linear server | Holds |
| `--labels` replaces the whole set | `issues.sh` update; Linear `labelIds` also replaces | Linear schema; `addedLabelIds` and `removedLabelIds` avoid it | Holds, with rule text |
| 75-row default and truncation warning | `issues.sh:482-522` | `pageInfo.hasNextPage` on every connection; Linear's default page is 50 [S3] | Holds when the caller reads `hasNextPage`; rule text needed |
| `activate` sets the assignee only when none is set | `issues.sh:2739` onward | None | Regression |
| `complete` posts the summary before the state change | `issues.sh:3160-3176` | None | Regression |
| RATELIMITED retry with backoff | `common.sh:280-290`, `common.sh:335-344` | None; Linear only answers 400 | Rule text needed |
| A canceled project loses to a live one of the same name | `lib/formatters.sh:27-40` | None; UUIDs avoid it | Rule text needed |

Five rows are regressions that only code can close without trusting a model to follow text: team target, agent label, reach lines, peer-only relations, and the validate-completion matrix. The `activate` and `complete` rows are regressions too, but each sits in one command that KEN-2335 keeps.

### Fields each caller reads

| Command | Caller and step | Fields read | Fields no caller reads |
|---|---|---|---|
| `teams get` | `open-terminal:2985-2987`; `tpm-audit.md` § 1.1.1 | `.team.key`; the audit also uses the name it passed | Every other team field |
| `issues get --with-bundle` | `start.md` § 3, `start-worktree.md` § 1, `dev-start.md` preflight: Ancestor gate (`skill-rules.md:70`) | `parent_id` chain, `state_type`, `blocked_by_open` of the item and container ancestors, ancestor titles for `(one PR)`, children | Description, comments, attachments |
| `issues get --format=compact` | `dev-start.md` § 1; `submit-pr.md` § 3.2 | `agent:*` and `design` labels; Location paths in the description | |
| `issues get` | `dev-implement.md` § 2.1 and `qa-review.md`: description; `submit-pr.md` § 2: title; `merge-pr.md` § 6: state and the Done-when boxes; `post-summary.md` § 2 and `dev-implement.md` § 9.2: `blocks`; `branch-size-check:280`: description; `lane-close:515`: `state_type`; `oversee.md` triage: `github_sync` | The union is broad; each caller reads one to three fields | None for the union |
| `comments list` | `dev-implement.md` § 2.1, `dev-fix.md`, `qa-review.md` | Comment bodies | Authors, timestamps |
| `issues validate-completion` | `dev-start.md` Check B: `.all_ok`; `container-close:278-300`: `all_ok`, failing rows, the parent's `state_type` and `has_summary` | | |
| `issues list --created-since --max` | `oversee-watch:1323` | `id`, `created_at` | Every other field: 2,650 bytes per row |
| `issues list --state "In Progress,In Review" --max` | `oversee-watch:3569` | `id`, `priority`, `state` | Every other field |
| `issues children --pending --recursive` | `merge-pr.md` § 4.1; `container-close:262-269` | `id`, `title`, `state_type` | |
| `issues activate`, `comments create`, `issues update`, `issues complete` | `dev-implement.md`, `submit-pr.md`, `post-summary.md`, `start-worktree.md` § 5.2, `merge-pr.md` § 6, `container-close:313` | Exit status; `activate`'s assignee line on stderr | The echoed issue body |
| Audit reads: `labels list`, `projects list`, `issues list --all-projects`, `comments bulk-list` | `tpm-audit.md` § 1.2 to § 1.5 | Label name, group, parent, team; project name, state, teams, order; issue id, title, description, state, labels, project, priority, estimate, parent, relations; comment bodies | |
| Cache file read | `reconcile-work-items:91-140` | `identifier`, `state.name`, `state.type`, `updatedAt`, `parent.identifier`, description | |

Only the two watch reads, `lane-close` and `open-terminal` read so few fields that a trim changes the request count or the bytes in a material way. The watch trim saves requests; the other two save bytes only.

### Skill text, like for like

The comparison sets the commands plus the skill against the raw route plus the rule text the raw route needs to keep § Guard parity, and the query documents a lane sends. [M] [K2]

| Side | Text | Bytes | Token figure |
|---|---|---|---|
| Commands | Rendered `.agents/skills/linear/SKILL.md` | 15,451 | 5,362 tokens when the Skill tool loads it in Claude Code [K2] |
| Raw route | KEN-2336's raw prompt: endpoint, token variable, header, schema path, team key | 579 | Not measured [K2] |
| Raw route | Rule text for the guard rows above ([M] `raw_route_rules`) | 2,024 | Not measured |
| Raw route | Query documents for one lane: bundle, state, team key, both watch reads, three lookups and two mutations ([M] `raw_queries`) | 1,338 | Not measured |
| **Raw route total** | | **3,941** | |

The raw route needs 26 percent of the skill's bytes when the rules move into text. The bytes are not the whole cost. Five rules become text that a model can skip, where today a script refuses the write. KEN-2336 measured first-try failures on the raw route from the 10,000-point query cap in 14 of 15 runs of three tasks [K2]; none of its runs tested a guard.

### Freshness options

| Option | Who owns it | Cost | Gaps |
|---|---|---|---|
| Cache fed by Linear webhooks | A new public HTTPS receiver that answers within 5 seconds, plus a fan-out to every host's cache. No such service exists in kendex. Creating the webhook needs a workspace admin or the `admin` scope [S2]; the app token holds `read,write` (`lib/auth.sh:117-121`), and a scope change revokes every app token. | 0 GraphQL requests per change; one hosted service and its signing secret | Linear retries a failed delivery 3 times, after 1 minute, 1 hour and 6 hours, then may disable the webhook [S2]. A missed event needs a delta read to repair it. |
| `updatedAt` delta read | The existing incremental path in `sync.sh:47-127`, filter `updatedAt gte` | 1 request per refresh for the issues delta, plus 1 for comments only when that delta returned a changed issue (`sync.sh:739-775`); the fixed phases add 33 more as written: 34 requests with no change, 35 with one (run `seed-incremental` plus the attachment pages) | Archive and trash do not change `updatedAt` (`sync.sh:461`), so deletions need reconcile, which fails in this workspace (KEN-2667). |
| No cache | Each call site reads live, as KEN-2335 specifies | 40 requests per lane; the four watches 132 requests an hour as written, 40 with the trimmed read | None for freshness. Each read pays its own request. |

The trimmed watch figure is 4 passes an hour times ⌈rows / 250⌉ pages per fleet: kendex 5, fleet 3, vg 1, talk 1, at the rows of runs `watch-pass-*`.

Linear's own guidance is to avoid polling, use webhooks, and filter or order by `updatedAt` when fetching all data. [S1] [S3]

### Sync runs during this research

Directive 1790845185, from the master session as corrected by owner note 1791064681, stops only the lane-end `sync --reconcile`, because of the reconcile argv bug (KEN-2440, now KEN-2667). A plain incremental sync and `session-status` are allowed. No run below reconciled, and none broke the directive.

- **20:13:33Z to 20:16:54Z, full sync from a missing cache.** The measurement run called `linear.sh session-status` to price the TPM cycle plan. With no cache, its auto-sync started a full `sync.sh` (`session-status.sh:66-70`). It was stopped after 93 issue pages and 15 comment pages: 108 requests and 53,805 points, all logged as label `session-status`. That is 4.3 percent of one API key's 2,500 requests an hour (108 / 2,500), and of the app bucket this fleet uses, 2.2 percent of its 5,000 requests and 2.7 percent of its 2,000,000 points. It wrote the sandbox base checkout's cache, `/home/dev/dev/kendex/.cache/linear`, through the worktree's `.cache` symlink; the partial cache was deleted after the run. [M]
- **20:19:44Z to about 20:30:30Z, planned scratch measurement.** Under exception 1791058163, into `tmp/ken-2685/scratch-cache`. It started as a full sync through a bug in `sync-price.sh`: the script sourced `sync.sh` while its own argument was set, and `sync.sh` runs `main` when sourced with a positional parameter (`sync.sh:900-907`). It finished issues and comments and was stopped in the projects phase. These requests passed the real `graphql_query` and were not logged: at least 156 (93 + 63) and at most 244. The script now clears its parameters before sourcing. [M]
- **21:54:45Z to 21:59:28Z, planned scratch measurement.** `linear.sh sync --full --no-attachments` into `tmp/linear-sync-scratch-KEN-2685`, every request logged as label `scratch-sync-full`: 156 requests and 111,405 points, the issues and comments phases; it ended before projects and wrote no `meta.json`. [M]
- **22:04:13Z to 22:16:11Z, planned scratch measurement.** Into `tmp/ken-2685/seed-cache`: the full sync (label `seed-full`, 207 requests, 134,475 points), a plain sync 7 seconds later (label `seed-incremental`, 7 requests, 10,810 points) and `sync --if-stale 15` (label `seed-if-stale`, 0 requests). [M]
- **Write-through, filed as KEN-2695.** Besides the 20:13Z run, live commands wrote the base checkout's cache through the same symlink later. Its directory dates from 21:53:22.556Z, 0.5 s after the only request the shim logged then: the `CreateComment` that posted this research's completion summary from this worktree (run `2026-10-03T21:53:22.046Z-comment-create`; the comment on KEN-2685 is dated 21:53:22.372Z). `comments/KEN-2685.json` there was last written at 21:53:37.859Z, when the shim logged no request; the lane's orchestrator reports its own live `issues validate-completion` from the lane session, outside the shim, at about that time. Later files there come from other sessions' comment writes: `comments/KEN-2694.json` at 21:57:36Z, `comments/KEN-2695.json` and `.comments.lock` at 22:45:40Z (`find` on the base cache, 22:46Z). `.comments.lock` is taken only by the single-comment writers (`cache.sh:67-79`). This research's validate-completion ran at 20:13:20.997Z to 20:13:21.844Z (label `validate-completion`); no file shows whether it wrote the cache, since the cache built at 20:13Z was deleted. From 22:00Z this research read Linear with `LINEAR_CACHE_ROOT` pointed at `tmp/ken-2685/reads-cache`, so its reads wrote there and not into the base checkout. [T7]

Every scratch cache was deleted at 2026-10-03T22:18:01Z: `tmp/ken-2685/scratch-cache` (75,160,651 bytes), `tmp/ken-2685/seed-cache` (55,525,696), `tmp/linear-sync-scratch-KEN-2685` (56,730,945) and `tmp/ken-2685/reads-cache` (3,183). [M] `scratch_deleted`

### Sources

- [M] `linear-fleet-load-research.evidence.json`: every logged request with its headers, the sampler, the counts, the sync runs, the control-host figures, the argv test, the rule text and the query documents. Run ids are UTC timestamps plus the query or command label. No token, issue text or cursor is stored.
- [R] `linear-fleet-load-research.raw.json`: the provider record. Exa refused the key; the three provider pages were read directly.
- [O] The overseer's answer to lane-mail ask 1791058128-12831-9940, read on the control VM at about 2026-10-03 20:10Z; its figures are in [M] `control_host`.
- [S1] https://linear.app/developers/rate-limiting, read 2026-10-03. Quoted: OAuth app "5,000" requests and "2,000,000" points hourly per user or app user; API key "up to 2,500 requests per hour" and "up to 3,000,000 points per hour"; single query "10,000 points"; "leaky bucket"; complexity "Each property is 0.1 point, each object is 1 point and any connection multiplies its children's points based on the given pagination argument, or the default 50"; HTTP 400 with `RATELIMITED`; avoid polling and use webhooks.
- [S2] https://linear.app/developers/webhooks, read 2026-10-03: events, `admin` scope, public HTTPS, 200 within 5 seconds, retries, `Linear-Signature`.
- [S3] https://linear.app/developers/pagination, read 2026-10-03: default 50, `first`/`after`, `pageInfo`, order by `updatedAt`.
- [K1] `docs/plans/linear-official-route-research.md` (KEN-2319). [K2] `docs/plans/linear-command-value-research.md` (KEN-2336).
- [L1] `skills/linear/scripts/lib/common.sh`. [L2] `skills/linear/scripts/commands/issues.sh`. [L3] `skills/linear/scripts/lib/issue-validation.sh`. [L4] `skills/linear/scripts/lib/auth.sh`. [L5] `skills/linear/scripts/commands/sync.sh`. [L6] `skills/linear/scripts/commands/session-status.sh`. [L7] `skills/orch/scripts/oversee-watch`. [L8] `skills/orch/scripts/lib/escapes.sh`. [L9] `skills/orch/scripts/container-close`. [L10] `skills/linear/scripts/lib/cache.sh` and `kendex.settings.toml`. All at `ef4100c7`.
- [D1] KEN-2689's cross-team links design, `cfc24d5a:docs/plans/linear-cross-team-links-design.md` on main (PR #3575, merged 2026-10-03T22:24:01Z, after this branch's base), § Read cost, § Linear's rules on keys and links and § Backlink measurement. Its figures are measured from headers on 2026-10-03.
- Linear issues, read live with `issues get` and `comments list` on 2026-10-03 at about 22:00Z: [T1] KEN-2440 and its cancel comment. [T2] KEN-2667. [T3] FLT-641. [T4] FLT-642. [T5] FLT-183. [T6] KEN-2693. [T7] KEN-2695.

The measured X-Complexity values do not follow the [S1] formula literally: a 250-row page of two scalar fields reports 4 points, where the formula gives 50 or more. Every price above uses the measured header, not the formula.

## Tradeoffs / Alternatives

| Choice | Load | Freshness | Guards | Cost to build |
|---|---|---|---|---|
| Keep the cache as it is | 247 to 436 requests per lane; the complexity bucket runs out at 11 to 20 starts at once | Stale between syncs; reconcile fails in this workspace, and plain sync with it once the stamp is missing or an hour old; initiatives always empty | Kept in code | None, but 20 workflow files and the launch briefs disagree today |
| Keep the cache with the fix set: seed (fleet), batched reconcile (KEN-2667), a reconcile stamp on every full sync, `sync --if-stale` per step | First sync 34 requests and 34,435 points instead of 234 and 158,100; each later step 0 when fresh, else 34 to 35 requests and 34,435 to 35,635 points; 16 more requests per reconciling sync | Up to the `--if-stale` age | Kept in code | A fleet item, KEN-2667, the stamp, KEN-2695, and 20 workflow files plus the briefs aligned |
| Change the cache: team filter, no attachment pull per sync, `updatedAt` delta only | Lower than now, still a fixed cost per sync | Same as the delta row | Kept in code | Rework of `sync.sh` that KEN-2335 deletes |
| Webhook-fed cache | Close to zero reads | Seconds | Kept in code | New hosted service, `admin` scope, token reissue |
| Drop the cache, thin commands over live reads (KEN-2335) | 40 requests and 16,083 points per lane | Always current | Kept in code when the five checks stay in the thin layer | Already in progress |
| Drop the commands too, raw GraphQL from skill text | Close to the thin layer | Always current | Five rules become text | KEN-2676 scope |

## Recommendation / Decision Criteria

Drop the cache, as KEN-2335 specifies. The decision rests on these figures:

- One lane costs 40 requests and 16,083 points without the cache on the live-read route (38 and 15,305 as lanes run today under fleet ruling gen81, § Today), against 247 and 184,090 with a warm cache and 436 and 306,515 with an empty one.
- With the seed restored, one seeded sync alone costs 34 requests and 34,435 points, 2.1 times a whole no-cache lane's points.
- At the fleets' caps, 38 lanes in one peak hour with the watches and an audit use 34.5 percent of the requests and 35.7 percent of the points on the live-read route, and 36.3 and 39.3 percent as lanes run today. With a cache, kendex's 20 lane starts at once exhaust the complexity bucket warm, and 11 starts do it on empty caches (time-resolved, § Peak concurrency and headroom). The static sums in the burst table are load, not thresholds; the recommendation rests on neither and follows from the per-lane cost.
- The cache gives no freshness or correctness gain to offset that: reconcile fails in this workspace, initiatives never load, and every sync reads every team's data.

Owed decisions, each closed:

1. **KEN-2335 keeps five checks in code.** The thin layer keeps the team-target refusal, the agent-label and reach checks on create, the peer-only relation check, and the validate-completion matrix. Recommendation to KEN-2335's lane; no new issue.
2. **KEN-2335 retries only RATELIMITED and 5xx answers.** A scope or validation 400 costs 3 requests today. Recommendation to KEN-2335; no new issue.
3. **The seed is the keep-cache fix, not this recommendation's.** Under drop, no fleet seed item is filed, and KEN-2693 closes when KEN-2335 removes the sync `session-status` runs. If the owner keeps the cache, the fleet item in § Lane cache seed, KEN-2667 and the reconcile stamp on every full sync are all required; the seed alone leaves the next sync failing once the seed's stamp is missing or an hour old.
4. **KEN-2667 goes with the cache.** Under drop, KEN-2335 deletes `reconcile_issues`, as KEN-2440's cancel comment set out; under keep, KEN-2667 is required.
5. **The workflow text goes with the cache.** KEN-2335 removes the sync lines listed in § Why lanes stopped syncing, as KEN-2440's cancel comment folded them in; until then the launch briefs override them.
6. **Team-limited writers use one OAuth app per team, not personal keys (KEN-2689's route choice).** Personal keys, one per team, all share the owner's 2,500 requests an hour [S1] [D1]. On that route the fleet's peak hour joins the read key's 54 requests: on the live-read route 1,727 + 54 = 1,781 (71.2 percent), or 1,845 (73.8 percent) if the hook passes keep their own clocks; as lanes run today 1,813 + 54 = 1,867 (74.7 percent), or 1,931 (77.2 percent). That is before any request the owner sends with another key. The requests left cover 17 more whole lanes on the live-read route (719 / 40) and 16 today (633 / 38). One app per team, its team access limited on its app details page, gives each team 5,000 requests and 2,000,000 points: kendex at its cap of 20, with its watch and one audit, needs 943 requests (18.9 percent) and 402,811 points (20.1 percent) on the live-read route (20 × 40 + 68 + 75; 20 × 16,083 + 24,836 + 56,315), and 1,065 (21.3 percent) and 489,290 (24.5 percent) today (20 × 38 + 68 + 237; 20 × 15,305 + 24,836 + 158,354). Requests bind on the personal route; its points share is 23.8 percent on the live-read route (713,167 of 3,000,000) and 26.2 percent today (785,642), plus 16 × ⌈2.5 × N⌉. App tokens also keep the app actor in Linear's history, where a personal key's writes show as the owner's ([D1] § Backlink measurement). The read key stays a personal key, as [D1] designs it.
7. **Dropped: add a team filter to sync.** The cache goes; the change spends work on code KEN-2335 deletes.
8. **Dropped: trim `lane-close` and `open-terminal` reads.** Each is one request either way; the saving is bytes only.
9. **Dropped: a webhook-fed cache.** It needs a new public service and the `admin` scope to fix a freshness problem that live reads do not have.

### Follow-ups

Filed:

- **KEN-2693** (Backlog): a lane with no cache pays a full sync on its first `session-status`; the 20:13Z run spent 108 requests and 53,805 points before it was stopped, and a whole one costs 234 and 158,100 (225 and 152,190 without drovr's rows, § Drovr). The fix is the seed, § Lane cache seed. [T6] [M]
- **KEN-2695** (Triage): live `linear.sh` commands in a worktree write the base checkout's cache through the `.cache` symlink (`kendex.settings.toml:363`, `cache.sh:65`); live reads write the cache too (§ Key Findings). [T7]
- **KEN-2667** (Triage): reconcile puts every cached id in one jq argument and fails at 6,488 ids; the same code runs in plain sync's hourly reconcile (`sync.sh:819-828`). [T2] [M]

For filing by the orchestrator:

- **Overseer watch reads.** `oversee-watch:1323` reads every row the team created since the watch's fixed `--since`, with every field, to use `id` and `created_at`; the kendex window is 18 days, 1,168 rows, 17 requests and 6,209 points per pass, and grows a day each day. `oversee-watch:3569` reads full rows to use `id`, `priority` and `state`. A trimmed read from the previous pass's start at 250 rows per page answers in 1 request at 4 points. Source: runs `watch-pass-kendex-18d`, `watch-created-trim-1d`, `watch-owed-trim`.
- **The app token lacks the initiative scope.** `initiatives list` and every sync's initiative phase fail with HTTP 400 at 3 requests each. `roadmap-create`'s two live initiative writes, `initiatives create` (`roadmap-create.md:62`) and `initiatives add-project` (`:71`), were not measured; its `cache initiatives list` (`:56`) sends no request and returns the empty cached list. Owner decision: a scope change reissues every app token. Source: runs `initiatives-list`, `seed-full`; `common.sh:345-363`.

## Risks / Unknowns

| Unknown or risk | Impact | Condition |
|---|---|---|
| Hook-started passes may keep their own long-pass clock | Adds 64 requests and 20,748 points an hour to the peak | The ps lines in [O] are cut off before `--since` ends; `oversee-watch:255,1158,1205` says they share it when it matches |
| Lane starts per hour in each fleet | Sustained load per hour; this report gives burst figures and a whole-life peak hour | Not measured from a lane |
| Attachment downloads from `uploads.linear.app` | Any limit on that host would add to the cache's cost | Not measured |
| Header remaining is approximate | One reading moved 21 requests between two calls 0.3 s apart | [M]; the sampler figures carry that noise |
| The fleet's use while sampling reflects today's state | Lanes with caches would draw more | No seed, no lane-end reconcile, live reads, until KEN-2335 lands or a seed returns |
| Unlogged requests in the 20:19Z scratch sync | Between 156 and 244 own requests in that window are not individually logged | § Sync runs; the sampler excludes that window |
| Plain sync's reconcile failure, after a missing or hour-old stamp, is read from the source | The keep-cache rows assume it | No reconciling sync ran; KEN-2667 observed the `--reconcile` form |

## Revisit Conditions

- KEN-2335 lands: re-measure one lane end to end on the thin layer with the shim, and compare with the 40-request figure.
- Linear changes the bucket sizes or the refill rule on [S1], or the headers report other limits.
- The app gains the `admin` or initiative scopes, which changes the webhook and initiatives rows.
- A seed or a lane-end sync returns while kendex's cap is 20 or more: a warm-cache relaunch at that cap exhausts the complexity bucket.
- A fleet's `--interval` falls below 900, or a watch runs months on one `--since`: the watch rows grow with both.

## Research Metadata

- Issue KEN-2685, round `1791058135743507053-2049`, branch `ken-2685`, base `ef4100c734d4fde4e8d48ee5479fc4df999e65b6`, 2026-10-03.
- Fix round `1791064790379545517-29071` (key `local-1791064548-225494-32075`): the control-host figures, the corrected rule, the scratch syncs `seed-full`, `seed-incremental` and `seed-if-stale`, the four `watch-pass-*` reads, the argv test, and live reads of KEN-2440, KEN-2667, KEN-2693, KEN-2695, FLT-641, FLT-642 and FLT-183, plus a fleet issue search. Every scratch cache deleted at 22:18:01Z. Added in the same round: drovr out of every consumer figure (owner note 1791065386), and the KEN-2689 read-key cost with the route choice for team-limited writers (overseer directive 1791066016-2083845-11968).
- Provider: Exa refused the configured key (HTTP 401, `INVALID_API_KEY`), so no Exa search ran. The three provider pages the issue and its subject name were read directly; no general web search ran. Mode recorded in [R] as `lite`, 3 queries attempted, 0 results.
- Measurement: the actor, method and run ids are in [M]. Own requests are logged with timestamps; the clean window holds none but the samples, and the 20:19Z scratch-sync window is excluded from every interval figure.
- Validation: `deep-research validate` on this report and [R].

[M]: linear-fleet-load-research.evidence.json
[R]: linear-fleet-load-research.raw.json
[K1]: linear-official-route-research.md
[K2]: linear-command-value-research.md
