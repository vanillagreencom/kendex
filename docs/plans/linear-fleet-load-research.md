# Findings: Linear fleet load, guard parity, fields and freshness

## Research Question

Every lane, VM overseer and local overseer reads and writes Linear as one application actor, so the whole fleet shares one rate-limit bucket. What does each workflow cost in requests and complexity points, with the cache and without it? How much headroom does the fleet have at peak concurrency? Which rules do the `linear.sh` commands enforce that a raw GraphQL route must keep? Which output fields does each caller read? How do the commands plus the skill compare with the raw route plus the rule text it needs? How can data stay fresh without polling? The answer decides whether the cache stays, changes or goes.

## Executive Summary

Drop the cache. Without it, one lane costs 35 requests and 14,123 complexity points plus three comment writes, from launch to close. With a warm cache the same lane costs 247 requests, because each of its five `sync --reconcile` calls costs 45 requests when one issue changed, and 44 when none did. On a host with an empty cache, the first sync is a full sync and the lane costs 446 requests. [M]

- A full sync costs 244 requests and 160,910 complexity points. It reads every team's issues and comments in the workspace, not only kendex's: 6,478 issues, of which 2,634 are kendex's, and 15,694 comments. [M]
- The complexity bucket, not the request bucket, limits the cache. Sync pages cost up to 8,805 points per request. Nine lanes that start on empty caches at the same time use more than the 2,000,000-point bucket. Without the cache the same limit is 385 lanes. [M]
- In a 70-minute window with no other request from this sandbox, the shared request bucket never fell below 4,994 of 5,000, and the complexity bucket never below 1,915,628 of 2,000,000. Under the no-sync rule the fleet runs far inside both. [M]
- Seven of the twelve rules the commands enforce have no owner on a raw route. KEN-2335's thin layer must keep five of them in code: the team target, the agent label and reach lines on create, peer-only blocking relations, and the validate-completion matrix. [L1] [L2] [L3]
- Freshness: no cache, with live reads, costs the least and needs no new owner. A webhook-fed cache needs a public HTTPS receiver and the `admin` scope, which the kendex app does not hold. [S2] [L4]

Two unplanned sync runs happened in this research. § Incidents states what ran and what was restored.

## Key Findings

- **Each sync is a fixed cost, paid before any read.** An incremental `sync --reconcile` with one changed issue still reads 27 attachment pages, 10 reconcile pages, 3 failed initiative requests and 5 other pages: 45 requests and 35,675 points. A lane runs five of them. The live reads they replace cost 14 requests. [M] [L5]
- **`session-status` runs a full sync by itself.** `session-status.sh` runs `sync.sh` whenever the cache is missing or older than 15 minutes (`skills/linear/scripts/commands/session-status.sh:66-70`). `tpm-cycle-plan` and `audit-issues` call it. Under owner rule 1790845185 every such call breaks the rule. This research triggered it once. [M] [L6]
- **Reconcile never removes a row in this workspace.** It reads at most 10 pages of 250 issue ids, then aborts when the API returned fewer than half of the cached ids (`skills/linear/scripts/commands/sync.sh:544-576`). The cache holds 6,478 issues, so every reconcile reads 2,500 ids, aborts, and spends 10 requests. [M] [L5]
- **The app token cannot read initiatives.** Linear answers HTTP 400 "Invalid scope: `initiative:read` or `initiative:write` required". `graphql_query` retries every non-200 answer, so each failed read costs 3 requests (`skills/linear/scripts/lib/common.sh:345-363`). Every sync, `initiatives list`, and the `roadmap-create` initiative steps fail this way. [M] [L1]
- **The overseer watch reads 2.6 KB per issue to use two fields.** Its new-issue read uses `id` and `created_at` only. A trimmed raw query at 250 rows per page answers the 3-day window of 354 rows in 2 requests (first page measured at 4 points), against 6 requests and 1,985 points now. [M] [L7]
- **Linear's rate-limit window does not reset hourly.** Every `X-RateLimit-*-Reset` header reads 3,600.2 to 3,600.3 seconds after the request. The bucket refills at a constant 1.39 requests and 555.6 points per second, as the provider page states. [M] [S1]

## Evidence and Sources

### Method

- **Actor**: `linear.sh auth-check` reports credential `app-token`, actor kind `application`, id `f9755405-2f06-46a6-b706-1f552ff74bef`, name `vanillagreen agents`, team `kendex`. Headers report 5,000 requests and 2,000,000 points. [M]
- **Command runs**: each `linear.sh` command ran with a logging `curl` shim first on `PATH`. The shim adds `-D` to the real `curl`, keeps the operation name, and drops the Authorization line. Each call is one row in [M] `calls`, keyed by its command label. [M]
- **Plain reads**: `probe.sh` posts one GraphQL document with the credential `linear.sh` selects (`skills/linear/scripts/lib/auth.sh:65-71`) and records every `X-RateLimit-*` header and `X-Complexity`. `sync-price.sh` sources `sync.sh` and runs each sync function with `graphql_query` replaced by the same recorder; no cache file is written. Each request is one row in [M] `runs`, keyed by its run id. [M]
- **Sampler**: `{ viewer { id } }` every 120 seconds from 20:10:16Z. Each sample costs 1 request and 1 point. [M] `sampler`.
- **Base**: kendex `ef4100c734d4fde4e8d48ee5479fc4df999e65b6`. Source citations name files at that commit. Date 2026-10-03.

### Bucket behaviour

| Quantity | Value | Source |
|---|---|---|
| Request bucket | 5,000, refill 5,000 per 3,600 s | [M] headers; [S1] "leaky bucket", "refilled with a constant rate of `LIMIT_AMOUNT / LIMIT_PERIOD`" |
| Complexity bucket | 2,000,000, refill 2,000,000 per 3,600 s | [M] headers; [S1] |
| Per-query cap | 10,000 points | [S1] |
| Reset header | Request time plus 3,600.2 to 3,600.3 s on every row | [M] all rows |
| Rate-limit answer | HTTP 400, `errors[].extensions.code` `RATELIMITED` | [S1]; `skills/linear/scripts/lib/common.sh:280-290` |
| Header noise | Remaining moved up by 21 between two calls 0.3 s apart | [M] run `20261003T203126992-sync-projects-full-p1` |

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
| `comments create` | 1 | not measured | | `skills/linear/scripts/commands/comments.sh:213`, the only request in create |
| `issues update --state` | 3 | 783 | | Derived: `GetIssue` 389, `GetState` 10, `UpdateIssue` 384, the measured parts of `activate`; `skills/linear/scripts/commands/issues.sh:1802,1951,2062` |
| `issues complete --done-when-met` | 4 | 1,172 | | Derived: one `get_issue` plus `issues update` (`skills/linear/scripts/commands/issues.sh:3135,3176`) |

A live list costs 1 team lookup plus one request per 75 rows (`skills/linear/scripts/commands/issues.sh:482-488`), at 384 points per page.

### Sync prices

Full sync, measured from the sync's own queries. [M]

| Phase | Requests | Points | Rows | Source |
|---|---|---|---|---|
| Issues, every team, archived included, 75 per page | 93 | 35,805 | 6,478 live after the archive filter | Unplanned run, label `session-status`, 20:13:33Z to 20:16:26Z |
| Comments, every team, 250 per page | 63 | 75,600 | 15,694 | Page cost from label `session-status`; row count from the scratch run (§ Incidents) |
| Projects, 75 per page | 1 | 8,805 | 55 | Runs `sync-projects-full` |
| Project dependencies, one request per project | 55 | 15,455 | | Runs `sync-projects-full`, 281 points each |
| Cycles, team filter | 1 | 395 | 7 | Run `sync-cycles` |
| Initiatives | 3 | none | 0, HTTP 400 scope error | Run `sync-initiatives`; 3 attempts from `common.sh:345-363` |
| Labels | 1 | 1,225 | 63 | Run `sync-labels` |
| Attachments, every page, on every sync | 27 | 23,625 | 6,655 | Runs `sync-attachments`, 875 points each |
| **Total** | **244** | **160,910** | | |

An incremental `sync --reconcile` reads each delta, the reconcile pages and every fixed phase again. [M] [L5]

| Phase | Requests | Points | Measured on |
|---|---|---|---|
| Issues changed since the last sync | 1 per 75 changed | 385 per page | 1 issue in 4 min, 26 in 60 min: runs `sync-issues-delta-4m`, `-60m` |
| Comments on those issues | 1 per 250, only when an issue changed | 1,200 per page | 3 and 71 comments: runs `sync-comments-delta-*` |
| Projects changed | 1, plus 1 per changed project | 8,805 per page, 281 per project | 0 changed: runs `sync-projects-delta-*` |
| Reconcile, forced or older than 60 min | 10 at the cap | 4 per page | Runs `reconcile-2613` |
| Cycles, initiatives, labels | 5 | 1,620 | As in the full sync |
| Attachments | 27 | 23,625 | As in the full sync |
| **Total, one change, reconcile forced** | **45** | **35,675** | |

Without a forced reconcile inside the hour the total is 35 requests and 35,635 points. Attachment downloads go to `uploads.linear.app`, not the GraphQL API; their count and limit were not measured.

### Load per workflow

One lane, one dev round, one review cycle, no fix rounds. The commands are the ones each workflow names at the cited line. "Warm" assumes a cache synced before the lane starts; "empty" is a host whose first sync is full, as in this sandbox before § Incidents. [M]

| Workflow and its Linear calls | Without cache: req / points | Warm cache: req / points | Empty cache: req / points |
|---|---|---|---|
| Lane start: `open-terminal` `teams get` (`skills/orch/scripts/open-terminal:2985`); bundle read in `start.md` § 3, `start-worktree.md` § 3 and `dev-start.md` preflight; compact read in `dev-start.md` § 1 | 6 / 5,195 | 137 / 107,277 | 336 / 232,512 |
| Dev round: `dev-implement.md` § 2.1 sync, `activate`, issue and comment reads, completion comment; `dev-start.md` Check B `validate-completion` | 12 / 3,498 + 1 comment | 55 / 38,779 + 1 comment | 55 / 38,779 + 1 comment |
| Review: `branch-size-check` issue read (`skills/orch/scripts/branch-size-check:280`); `qa-review.md` issue and comment reads | 3 / 783 | 0 / 0 | 0 / 0 |
| Submit: `branch-size-check`; title read; summary comment (`submit-pr.md:419`) | 3 / 778 + 1 comment | 1 / 1 comment | 1 / 1 comment |
| Post-summary and In Review (`start-worktree.md` § 5) | 4 / 783 + 1 comment | 4 / 783 + 1 comment | 4 / 783 + 1 comment |
| Merge and post-merge: children read (`merge-pr.md` § 4.1), sync, issue read, `issues complete` (`merge-pr.md:316-330`) | 6 / 2,697 | 49 / 36,847 | 49 / 36,847 |
| Lane close: `issues get` (`skills/orch/scripts/lane-close:515`) | 1 / 389 | 1 / 389 | 1 / 389 |
| **One lane** | **35 / 14,123** | **247 / 184,075** | **446 / 309,310** |
| Overseer watch, one long pass: new-issue read (`oversee-watch:1323`), 1-day or 3-day window | 3 / 833 to 6 / 1,985 | Same: the watch reads live | Same |
| Overseer watch, per hour at `--interval 240` | 45 / 12,495 to 90 / 29,775 | Same | Same |
| Overseer heartbeat: owed read (`oversee-watch:3569`), at most once per 25 long passes | 2 / 449 | Same | Same |
| TPM audit, team mode (`tpm-audit.md` § 1.1.1 to § 1.5) | 75 / 56,315 | 3 / 254 + one sync | 3 / 254 + 244 / 160,910 |
| `reconcile-work-items` | 36 / 13,505 | 0 + one sync | 244 / 160,910 |

The audit without a cache reads the comparison list once (36 requests) and the team's comments as one connection: 29 pages of 250 for 7,119 kendex comments, each page 1,200 points (run `comments-team-page`). As written it also reads the four-state list separately, 5 requests that the six-state list already holds.

### Peak concurrency and headroom

The orchestrator fills each placeholder row from the overseer's answer to ask 1791058128-12831-9940. `O` is the number of overseers, `I` a watch's `--interval` in seconds, `N` the issues created since that fleet's `--since`, `Lstart` the lane starts in one burst.

| Load source | Count | Requests per hour | Points per hour | Source |
|---|---|---|---|---|
| VM overseer watches | PLACEHOLDER: count (the issue names 4); each `--interval` | `O × (3600 / I) × (1 + ⌈N / 75⌉)` | `O × (3600 / I) × (65 + 384 × ⌈N / 75⌉)` | Overseer answer |
| Local overseer watches | PLACEHOLDER: count; each `--interval` | Same formula | Same formula | Overseer answer |
| Heartbeat owed reads | One per watch | `O × 2 × 3600 / (25 × I)` | `O × 449 × 3600 / (25 × I)` | `oversee-watch:3978` |
| Lane starts per fleet | PLACEHOLDER: each fleet's `ORCH_OVERSEER_LANES` (kendex commits 20, `kendex.settings.toml:124`) | `Lstart × 6` without cache, `× 137` warm, `× 336` empty | `Lstart × 5,195`, `× 107,277`, `× 232,512` | § Load per workflow |
| Rest of each lane | Same caps | `× 29` without cache, `× 110` with cache | `× 8,928`, `× 76,798` | § Load per workflow |
| One TPM audit | 1 | 75 without cache; 3 plus a sync with it | 56,315; 254 plus a sync | § Load per workflow |
| Recorded RATELIMITED answers | PLACEHOLDER: count and log | | | Overseer answer |

Headroom: a burst empties a bucket when its cost exceeds the bucket plus the refill during the burst. With no spread, the lane-start count that empties each bucket is:

| Lane starts at once | Request bucket (5,000) | Complexity bucket (2,000,000) | First to empty |
|---|---|---|---|
| Without cache | 834 | 385 | Complexity, at 385 |
| Warm cache | 37 | 19 | Complexity, at 19 |
| Empty cache | 15 | 9 | Complexity, at 9 |

Each 10 minutes of spread adds 833 requests and 333,333 points of refill. One fleet at the committed cap of 20 lanes, all starting together, empties the complexity bucket with a warm cache and both buckets with empty caches. Without the cache it uses 120 requests and 103,900 points. The watch adds at most 90 requests and 29,775 points per overseer-hour.

Odds of a RATELIMITED answer:

- **Without cache**: no workload in the table comes near either bucket. A RATELIMITED answer needs more than 385 lane starts inside a few minutes.
- **Warm cache**: likely when a fleet starts or merges 19 or more lanes inside a few minutes, since each sync spends 35,675 points.
- **Empty cache**: likely when 9 lanes start on new hosts together; one 20-lane fleet relaunch does it every time.

### Fleet consumption

The sampler ran 98 minutes, 20:10:16Z to 21:48:45Z, 50 samples. From 20:38:22Z to 21:48:45Z, 70 minutes and 36 samples, this sandbox sent nothing to Linear but the samples; that is the clean window. [M] `fleet_consumption`, `sampler`

| Figure | Clean window | Whole run |
|---|---|---|
| Lowest requests remaining | 4,994 at 21:30:41Z | 4,834 at 20:10:08Z, before the first measurement |
| Samples at 4,998 or more | 35 of 36 | 46 of 50 at 4,995 or more |
| Lowest complexity remaining | 1,915,628 at 21:46:44Z | Same |
| Complexity gaps at a sample | 6 gaps: 7,668; 16,328; 752; 5; 84,372; 18,514 | |

The fleet's draw cannot be read as "remaining at the start minus remaining at the end". The bucket refills continuously and stops at its cap, and the reset header names no window (§ Bucket behaviour). While the bucket sits at its cap, any draw below the refill rate leaves no trace. What the headers show:

- The request bucket never fell below 99.8 percent in the clean window. The fleet's request draw stayed below the refill rate of 83 per minute for nearly all 70 minutes.
- The fleet drew at least 127,639 complexity points in the clean window: the sum of the gaps. The largest, 84,372 points, came inside the 152 seconds before 21:46:44Z, which is how long the refill takes to close that gap. One heavy read, such as a full-backlog list or a sync-sized pull, explains it.
- At 20:10:08Z the bucket stood 166 requests below its cap, of which this research had sent 1. Some caller drew at least 165 requests within the 2 minutes before.
- No sample came near either limit. At the load the fleet ran in this window, under the no-sync rule, the odds of a RATELIMITED answer were nil.

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
| `issues get --with-bundle` | `start.md` § 3, `start-worktree.md` § 3, `dev-start.md` preflight: Ancestor gate (`skill-rules.md:70`) | `parent_id` chain, `state_type`, `blocked_by_open` of the item and container ancestors, ancestor titles for `(one PR)`, children | Description, comments, attachments |
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
| `updatedAt` delta read | The existing incremental path in `sync.sh:47-127`, filter `updatedAt gte` | 2 requests per refresh for issues and comments; the fixed phases add 33 more as written | Archive and trash do not change `updatedAt` (`sync.sh:461`), so deletions need reconcile, which aborts in this workspace. |
| No cache | Each call site reads live, as KEN-2335 specifies | 35 requests per lane, 15 to 30 per watch-hour trimmed | None for freshness. Each read pays its own request. |

Linear's own guidance is to avoid polling, use webhooks, and filter or order by `updatedAt` when fetching all data. [S1] [S3]

### Incidents

- **20:13:33Z to 20:16:54Z, unplanned sync through `session-status`.** The measurement run called `linear.sh session-status` to price the TPM cycle plan. Its auto-sync started a full `sync.sh` against the sandbox base checkout's cache (`/home/dev/dev/kendex/.cache/linear`, empty before). The run was stopped after 93 issue pages and 15 comment pages: 108 requests, 53,805 points, all logged as label `session-status`. The partial cache was deleted; its directory did not exist before 20:13Z, and every file in it dated from that run. [M]
- **20:19:44Z to about 20:30:30Z, unplanned sync in scratch.** `sync-price.sh` sourced `sync.sh` while its own argument was set. `sync.sh` runs its `main` when sourced with a positional parameter (`sync.sh:900-907`), so a full sync ran. `LINEAR_CACHE_ROOT` pointed at `tmp/ken-2685/scratch-cache`, so it wrote only there. It finished issues (installed 20:22:42Z) and comments (15,694 rows by 20:24:55Z) and was stopped in the projects phase. These requests passed the real `graphql_query` and were not logged: at least 156 (93 + 63) and at most 244. The script now clears its parameters before sourcing. [M]

Both runs are breaches of owner rule 1790845185. Their figures are used above because they measure the same queries a sync sends.

### Sources

- [M] `linear-fleet-load-research.evidence.json`: every logged request with its headers, the sampler, the counts, the rule text and the query documents. Run ids are UTC timestamps plus the query or command label. No token, issue text or cursor is stored.
- [R] `linear-fleet-load-research.raw.json`: the provider record. Exa refused the key; the three provider pages were read directly.
- [S1] https://linear.app/developers/rate-limiting, read 2026-10-03. Quoted: OAuth app "5,000" requests and "2,000,000" points hourly per user or app user; API key "up to 2,500 requests per hour" and "up to 3,000,000 points per hour"; single query "10,000 points"; "leaky bucket"; complexity "Each property is 0.1 point, each object is 1 point and any connection multiplies its children's points based on the given pagination argument, or the default 50"; HTTP 400 with `RATELIMITED`; avoid polling and use webhooks.
- [S2] https://linear.app/developers/webhooks, read 2026-10-03: events, `admin` scope, public HTTPS, 200 within 5 seconds, retries, `Linear-Signature`.
- [S3] https://linear.app/developers/pagination, read 2026-10-03: default 50, `first`/`after`, `pageInfo`, order by `updatedAt`.
- [K1] `docs/plans/linear-official-route-research.md` (KEN-2319). [K2] `docs/plans/linear-command-value-research.md` (KEN-2336).
- [L1] `skills/linear/scripts/lib/common.sh`. [L2] `skills/linear/scripts/commands/issues.sh`. [L3] `skills/linear/scripts/lib/issue-validation.sh`. [L4] `skills/linear/scripts/lib/auth.sh`. [L5] `skills/linear/scripts/commands/sync.sh`. [L6] `skills/linear/scripts/commands/session-status.sh`. [L7] `skills/orch/scripts/oversee-watch`. All at `ef4100c7`.

The measured X-Complexity values do not follow the [S1] formula literally: a 250-row page of two scalar fields reports 4 points, where the formula gives 50 or more. Every price above uses the measured header, not the formula.

## Tradeoffs / Alternatives

| Choice | Load | Freshness | Guards | Cost to build |
|---|---|---|---|---|
| Keep the cache as it is | 247 to 446 requests per lane; complexity bucket empties at 9 to 19 simultaneous starts | Stale between syncs; reconcile aborts; initiatives always empty | Kept in code | None, but the owner's no-sync rule and `session-status` conflict today |
| Change the cache: team filter, no attachment pull per sync, `updatedAt` delta only, fix reconcile | Lower than now, still a fixed cost per sync | Same as the delta row | Kept in code | Rework of `sync.sh` that KEN-2335 deletes |
| Webhook-fed cache | Close to zero reads | Seconds | Kept in code | New hosted service, `admin` scope, token reissue |
| Drop the cache, thin commands over live reads (KEN-2335) | 35 requests and 14,123 points per lane | Always current | Kept in code when the five checks stay in the thin layer | Already in progress |
| Drop the commands too, raw GraphQL from skill text | Close to the thin layer | Always current | Five rules become text | KEN-2676 scope |

## Recommendation / Decision Criteria

Drop the cache, as KEN-2335 specifies. The decision rests on these figures:

- One lane costs 35 requests and 14,123 points without the cache, against 247 and 184,075 with a warm cache and 446 and 309,310 with an empty one.
- The complexity bucket empties at 9 simultaneous lane starts on empty caches and 19 on warm ones; without the cache it takes 385.
- The cache gives no freshness or correctness gain to offset that: reconcile aborts in this workspace, initiatives never load, and every sync reads every team's data.

Owed decisions, each closed:

1. **KEN-2335 keeps five checks in code.** The thin layer keeps the team-target refusal, the agent-label and reach checks on create, the peer-only relation check, and the validate-completion matrix. Recommendation to KEN-2335's lane; no new issue.
2. **KEN-2335 retries only RATELIMITED and 5xx answers.** A scope or validation 400 costs 3 requests today. Recommendation to KEN-2335; no new issue.
3. **Follow-up for filing: `session-status` auto-sync.** Remove the `sync.sh` call at `session-status.sh:66-70` now, before KEN-2335 lands, because every `tpm-cycle-plan` and `audit-issues` run breaks owner rule 1790845185 through it.
4. **Follow-up for filing: trim the overseer watch reads.** `oversee-watch:1323` and `:3569` read `id`, `created_at`, `priority` and `state` only. A 250-row trimmed read cuts a 3-day pass from 6 requests to 2.
5. **Follow-up for filing: initiatives under the app actor.** The app token lacks `initiative:read` and `initiative:write`; `roadmap-create.md:56-71` fails. The owner decides between a scope change, which reissues every app token, and moving those steps to another actor.
6. **Dropped: fix reconcile's 10-page cap.** The cache goes; the fix spends work on code KEN-2335 deletes.
7. **Dropped: add a team filter to sync.** Same reason as 6.
8. **Dropped: trim `lane-close` and `open-terminal` reads.** Each is one request either way; the saving is bytes only.
9. **Dropped: a webhook-fed cache.** It needs a new public service and the `admin` scope to fix a freshness problem that live reads do not have.
10. **Placeholders**: the orchestrator fills § Peak concurrency and headroom from the overseer's answer; the formulas there give the result without new measurement.

## Risks / Unknowns

| Unknown or risk | Impact | Condition |
|---|---|---|
| Overseer count, intervals, other fleets' lane caps, recorded 429s | The peak table's totals | Filled from the overseer's answer |
| Lane starts per hour in each fleet | Sustained load per hour; this report gives burst figures | Not measured from a lane |
| Comment writes' complexity | Up to 3 small mutations per lane | Not measured; `comments create` is one request |
| Attachment downloads from `uploads.linear.app` | Any limit on that host would add to the cache's cost | Not measured |
| Header remaining is approximate | One reading moved 21 requests between two calls 0.3 s apart | [M]; the sampler figures carry that noise |
| The fleet's use while sampling reflects the no-sync regime | A fleet with caches would draw more | Owner rule 1790845185 is in force |
| Unlogged requests in the scratch sync | Between 156 and 244 own requests in that window are not individually logged | § Incidents; the sampler excludes that window |

## Revisit Conditions

- KEN-2335 lands: re-measure one lane end to end on the thin layer with the shim, and compare with the 35-request figure.
- Linear changes the bucket sizes or the refill rule on [S1], or the headers report other limits.
- The app gains the `admin` or initiative scopes, which changes the webhook and initiatives rows.
- A fleet raises its lane cap above 19 while any cache remains.

## Research Metadata

- Issue KEN-2685, round `1791058135743507053-2049`, branch `ken-2685`, base `ef4100c734d4fde4e8d48ee5479fc4df999e65b6`, 2026-10-03.
- Provider: Exa refused the configured key (HTTP 401, `INVALID_API_KEY`), so no Exa search ran. The three provider pages the issue and its subject name were read directly; no general web search ran. Mode recorded in [R] as `lite`, 3 queries attempted, 0 results.
- Measurement: the actor, method and run ids are in [M]. Own requests are logged with timestamps; the clean window holds none but the samples, and the scratch-sync window is excluded from every interval figure.
- Validation: `deep-research validate` on this report and [R].

[M]: linear-fleet-load-research.evidence.json
[R]: linear-fleet-load-research.raw.json
[K1]: linear-official-route-research.md
[K2]: linear-command-value-research.md
